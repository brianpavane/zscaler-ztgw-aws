#!/usr/bin/env python3
"""ztgw.py - manage a Zscaler Zero Trust Gateway (ZTGW) for AWS.

The official zscaler/ztc Terraform provider has no Zero Trust Gateway
resource, so stacks/02-ztgw drives this client from Terraform:

  create    create the gateway (or adopt one with the same name), wait for
            HEALTHY, activate                     spec: ZTGW_SPEC env (JSON)
  update    apply mutable settings (account groups, allowed accounts,
            additional AWS accounts), activate    spec: ZTGW_SPEC env
  delete    delete the gateway, wait until gone, optionally delete the ZTC
            location it leaves behind, activate   spec: ZTGW_SPEC env
  read      Terraform `external` data source: JSON query on stdin, flat
            JSON object of strings on stdout
  activate  activate pending Cloud & Branch Connector changes
  regions   print the AWS regions the tenant supports for ZTGW

Workload Discovery (WDS) onboarding, used by the Phase 3 stacks:

  wds-settings      `external` data source: Zscaler's trusted discovery role
                    (trusted_account_id, trusted_role_name, trusted_role_arn)
  account-register  register an AWS account in Partner Integrations
                    (idempotent: adopts an existing registration)
                                                        spec: ZTGW_ACCOUNT env
  account-read      `external` data source: {exists, id, external_id, name,
                    event_bus_name}
                    for the AWS account in the stdin query {aws_account_id}
  account-delete    remove the registration (idempotent)  spec: ZTGW_ACCOUNT env
  wds-verify        ask Zscaler to verify the discovery role in the customer
                    account; retries while IAM propagates   spec: ZTGW_WDS env
  group-add      add a public cloud account to an account group, activate
  group-remove   remove it again (idempotent)            spec: ZTGW_GROUP env

API: Cloud & Branch Connector API, /ztGateway endpoints
(https://automate.zscaler.com, "Zero Trust Gateway").

Authentication (read from the environment that scripts/run.sh prepares):
  ZSCALER_USE_LEGACY_CLIENT=false (OneAPI):
      ZSCALER_CLIENT_ID, ZSCALER_CLIENT_SECRET, ZSCALER_VANITY_DOMAIN,
      [ZSCALER_CLOUD]   (empty for production)
  ZSCALER_USE_LEGACY_CLIENT=true (Legacy):
      ZTC_USERNAME, ZTC_PASSWORD, ZTC_API_KEY, ZTC_CLOUD (production cloud name, e.g. zscalertwo)

Credentials are never accepted as arguments and never printed. TLS
certificates are always verified. Standard library only; run with
`python3 -I`.
"""

from __future__ import annotations

import json
import os
import re
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from typing import Any, Callable, Dict, List, Optional, Tuple

USER_AGENT = "zscaler-ztgw-aws/ztgw.py"
HTTP_TIMEOUT = 60
MAX_RETRIES = 5
POLL_INTERVAL = 15
LEGACY_CLOUDS = {
    "zscaler", "zscalerone", "zscalertwo", "zscalerthree", "zscloud",
    "zscalerbeta", "zscalergov", "zscalerten",
}
NAME_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9 _.-]{0,127}$")
AZ_ID_RE = re.compile(r"^[a-z]{2,6}[0-9]-az[0-9]{1,2}$")
REGION_RE = re.compile(r"^[a-z]{2}(-gov)?-[a-z]+-[0-9]$")
AWS_ACCOUNT_RE = re.compile(r"^[0-9]{12}$")


class ZtgwError(Exception):
    """An error to report to the operator (no traceback)."""


def log(msg: str) -> None:
    print(f"[ztgw] {msg}", file=sys.stderr, flush=True)


# --------------------------------------------------------------------------
# HTTP transport (injectable for tests)
# --------------------------------------------------------------------------

Response = Tuple[int, Dict[str, str], bytes]
Transport = Callable[[str, str, Dict[str, str], Optional[bytes]], Response]


def urllib_transport(method: str, url: str, headers: Dict[str, str],
                     body: Optional[bytes]) -> Response:
    """Real transport. Uses the default SSL context: certificates verified."""
    if not url.startswith("https://"):
        raise ZtgwError(f"refusing non-HTTPS URL: {url}")
    req = urllib.request.Request(url, data=body, method=method, headers=headers)
    try:
        with urllib.request.urlopen(req, timeout=HTTP_TIMEOUT) as resp:
            return resp.status, dict(resp.headers.items()), resp.read()
    except urllib.error.HTTPError as e:
        return e.code, dict(e.headers.items()) if e.headers else {}, e.read() or b""
    except urllib.error.URLError as e:
        raise ZtgwError(f"{method} {url.split('?')[0]}: {e.reason}") from None
    except (TimeoutError, OSError) as e:  # read timeouts are not always URLError
        raise ZtgwError(f"{method} {url.split('?')[0]}: {e}") from None


# --------------------------------------------------------------------------
# Authentication
# --------------------------------------------------------------------------

def obfuscate_api_key(api_key: str, timestamp_ms: str) -> str:
    """Zscaler legacy API key obfuscation (same algorithm as zscaler-sdk-go)."""
    if len(timestamp_ms) < 6 or len(api_key) < 12:
        raise ZtgwError("ZTC_API_KEY is too short to be a valid API key")
    high = timestamp_ms[-6:]
    low = f"{int(high) >> 1:06d}"
    key = "".join(api_key[int(c)] for c in high)
    key += "".join(api_key[int(c) + 2] for c in low)
    return key


def _env(name: str) -> str:
    return os.environ.get(name, "").strip()


def _require(*names: str) -> None:
    missing = [n for n in names if not _env(n)]
    if missing:
        raise ZtgwError("missing environment variable(s): " + ", ".join(missing)
                        + " (run through scripts/run.sh)")


class Client:
    """Minimal Cloud & Branch Connector API client (OneAPI or Legacy)."""

    def __repr__(self) -> str:  # never expose credentials or tokens
        return f"<ztgw.Client legacy={self.legacy} base_url={self.base_url}>"

    def __init__(self, transport: Transport = urllib_transport,
                 sleep: Callable[[float], None] = time.sleep,
                 clock: Callable[[], float] = time.time) -> None:
        self._transport = transport
        self._sleep = sleep
        self._clock = clock
        self.legacy = _env("ZSCALER_USE_LEGACY_CLIENT").lower() == "true"
        self._token: Optional[str] = None
        self._token_expiry = 0.0
        self._session: Optional[str] = None
        # Credentials are captured once, here, and kept in private attributes.
        self._creds: Dict[str, str] = {}

        if self.legacy:
            _require("ZTC_USERNAME", "ZTC_PASSWORD", "ZTC_API_KEY", "ZTC_CLOUD")
            cloud = _env("ZTC_CLOUD").lower()
            if cloud not in LEGACY_CLOUDS:
                raise ZtgwError(f"ZTC_CLOUD '{cloud}' is not a known Zscaler cloud")
            self.base_url = f"https://connector.{cloud}.net/api/v1"
            self._creds = {k: _env(k) for k in ("ZTC_USERNAME", "ZTC_PASSWORD", "ZTC_API_KEY")}
        else:
            if not _env("ZSCALER_CLIENT_SECRET") and _env("ZSCALER_PRIVATE_KEY"):
                raise ZtgwError("ztgw.py supports OneAPI client-secret auth only; "
                                "set ZSCALER_CLIENT_SECRET (private-key JWT is not supported)")
            _require("ZSCALER_CLIENT_ID", "ZSCALER_CLIENT_SECRET", "ZSCALER_VANITY_DOMAIN")
            cloud = _env("ZSCALER_CLOUD").lower()
            if cloud in ("gov", "govus"):
                raise ZtgwError("FedRAMP clouds are not supported by ztgw.py")
            if not re.fullmatch(r"[a-z0-9-]*", cloud):
                raise ZtgwError(f"invalid ZSCALER_CLOUD '{cloud}'")
            vanity = _env("ZSCALER_VANITY_DOMAIN")
            if not re.fullmatch(r"[A-Za-z0-9-]+", vanity):
                raise ZtgwError("invalid ZSCALER_VANITY_DOMAIN")
            if cloud in ("", "production"):
                self.token_url = f"https://{vanity}.zslogin.net/oauth2/v1/token"
                self.base_url = "https://api.zsapi.net/ztw/api/v1"
            else:
                self.token_url = f"https://{vanity}.zslogin{cloud}.net/oauth2/v1/token"
                self.base_url = f"https://api.{cloud}.zsapi.net/ztw/api/v1"
            self._creds = {k: _env(k) for k in ("ZSCALER_CLIENT_ID", "ZSCALER_CLIENT_SECRET")}

    # -- auth ---------------------------------------------------------------

    def _oneapi_token(self) -> str:
        if self._token and self._clock() < self._token_expiry - 60:
            return self._token
        form = urllib.parse.urlencode({
            "grant_type": "client_credentials",
            "client_id": self._creds["ZSCALER_CLIENT_ID"],
            "client_secret": self._creds["ZSCALER_CLIENT_SECRET"],
            "audience": "https://api.zscaler.com",
        }).encode()
        status, _, body = self._transport("POST", self.token_url, {
            "Content-Type": "application/x-www-form-urlencoded",
            "Accept": "application/json",
            "User-Agent": USER_AGENT,
        }, form)
        if status != 200:
            raise ZtgwError(f"OneAPI authentication failed (HTTP {status})")
        try:
            data = json.loads(body)
            self._token = data["access_token"]
        except (ValueError, KeyError):
            raise ZtgwError("OneAPI authentication returned no access_token") from None
        self._token_expiry = self._clock() + float(data.get("expires_in", 3600))
        return self._token

    def _legacy_login(self) -> str:
        if self._session:
            return self._session
        ts = str(int(self._clock() * 1000))
        payload = json.dumps({
            "username": self._creds["ZTC_USERNAME"],
            "password": self._creds["ZTC_PASSWORD"],
            "apiKey": obfuscate_api_key(self._creds["ZTC_API_KEY"], ts),
            "timestamp": ts,
        }).encode()
        status, headers, _ = self._transport("POST", self.base_url + "/auth", {
            "Content-Type": "application/json",
            "User-Agent": USER_AGENT,
        }, payload)
        if status != 200:
            raise ZtgwError(f"Legacy authentication failed (HTTP {status})")
        cookie = next((v for k, v in headers.items() if k.lower() == "set-cookie"), "")
        m = re.search(r"JSESSIONID=([^;]+)", cookie)
        if not m:
            raise ZtgwError("Legacy authentication returned no JSESSIONID")
        self._session = m.group(1)
        return self._session

    def close(self) -> None:
        """End the legacy session (OneAPI tokens simply expire)."""
        if self.legacy and self._session:
            try:
                self._transport("DELETE", self.base_url + "/auth", {
                    "Cookie": f"JSESSIONID={self._session}", "User-Agent": USER_AGENT,
                }, None)
            except ZtgwError:
                pass
            self._session = None

    def _auth_headers(self) -> Dict[str, str]:
        if self.legacy:
            return {"Cookie": f"JSESSIONID={self._legacy_login()}"}
        return {"Authorization": f"Bearer {self._oneapi_token()}"}

    # -- requests -----------------------------------------------------------

    def request(self, method: str, path: str, body: Any = None,
                query: Optional[Dict[str, Any]] = None,
                ok_statuses: Tuple[int, ...] = (200, 201, 204)) -> Tuple[int, Any]:
        url = self.base_url + path
        if query:
            url += "?" + urllib.parse.urlencode({k: v for k, v in query.items() if v is not None})
        data = json.dumps(body).encode() if body is not None else None
        reauthed = False
        for attempt in range(1, MAX_RETRIES + 1):
            headers = {"Accept": "application/json", "User-Agent": USER_AGENT}
            headers.update(self._auth_headers())
            if data is not None:
                headers["Content-Type"] = "application/json"
            status, resp_headers, raw = self._transport(method, url, headers, data)
            if status == 401 and not reauthed:
                reauthed = True
                self._token, self._session = None, None
                continue
            # POST creates are not idempotent: a 5xx may arrive after the
            # object was created, so the caller looks it up instead of the
            # request being re-sent (which would create a duplicate).
            if status == 429 or (status >= 500 and method != "POST"):
                retry_after = next((v for k, v in resp_headers.items()
                                    if k.lower() == "retry-after"), "")
                delay = float(retry_after) if retry_after.isdigit() else min(2 ** attempt, 30)
                log(f"{method} {path}: HTTP {status}, retry {attempt}/{MAX_RETRIES} in {delay:.0f}s")
                self._sleep(delay)
                continue
            parsed = _parse_json(raw)
            if status in ok_statuses:
                return status, parsed
            raise ZtgwError(f"{method} {path}: HTTP {status}: {_error_text(parsed, raw)}")
        raise ZtgwError(f"{method} {path}: giving up after {MAX_RETRIES} attempts")

    def get(self, path: str, **query: Any) -> Any:
        return self.request("GET", path, query=query or None)[1]


def _parse_json(raw: bytes) -> Any:
    if not raw:
        return None
    try:
        return json.loads(raw)
    except ValueError:
        return None


def _error_text(parsed: Any, raw: bytes) -> str:
    if isinstance(parsed, dict):
        code = parsed.get("code", "")
        msg = parsed.get("message", "")
        if code or msg:
            return f"{code} {msg}".strip()
    return raw[:300].decode("utf-8", "replace")


def _as_list(data: Any) -> List[Dict[str, Any]]:
    if isinstance(data, list):
        return data
    if isinstance(data, dict):
        for key in ("list", "gateways", "items", "data"):
            if isinstance(data.get(key), list):
                return data[key]
    return []


# --------------------------------------------------------------------------
# Spec
# --------------------------------------------------------------------------

def load_spec() -> Dict[str, Any]:
    raw = os.environ.get("ZTGW_SPEC", "")
    if not raw:
        raise ZtgwError("ZTGW_SPEC is not set")
    try:
        spec = json.loads(raw)
    except ValueError:
        raise ZtgwError("ZTGW_SPEC is not valid JSON") from None
    return validate_spec(spec)


def validate_spec(spec: Dict[str, Any]) -> Dict[str, Any]:
    if not isinstance(spec, dict):
        raise ZtgwError("ZTGW_SPEC must be a JSON object")
    name = spec.get("name", "")
    if not isinstance(name, str) or not NAME_RE.match(name):
        raise ZtgwError(f"invalid gateway name {name!r}")
    region = spec.get("region", "")
    if region and not REGION_RE.match(region):
        raise ZtgwError(f"invalid AWS region {region!r}")
    for az in spec.get("availability_zone_ids", []) or []:
        if not AZ_ID_RE.match(str(az)):
            raise ZtgwError(f"invalid AZ ID {az!r} (expected e.g. usw2-az1)")
    for acct in spec.get("additional_aws_accounts", []) or []:
        if not AWS_ACCOUNT_RE.match(str(acct)):
            raise ZtgwError(f"invalid AWS account ID {acct!r}")
    for key in ("account_group_ids", "allowed_account_ids"):
        for v in spec.get(key, []) or []:
            if not isinstance(v, int) or isinstance(v, bool) or v <= 0:
                raise ZtgwError(f"{key} must contain positive integers")
    loc = spec.get("location_name", "")
    if loc and not NAME_RE.match(loc):
        raise ZtgwError(f"invalid location name {loc!r}")
    return spec


def _region_code(region: str) -> str:
    return region.upper().replace("-", "_")


def _norm_region(value: Any) -> str:
    return str(value or "").lower().replace("_", "-")


def mutable_prov_data(spec: Dict[str, Any]) -> Dict[str, Any]:
    return {
        "accountGroups": [{"id": i} for i in sorted(spec.get("account_group_ids") or [])],
        "allowedAccounts": [{"id": i} for i in sorted(spec.get("allowed_account_ids") or [])],
        "additionalAwsAccounts": sorted(spec.get("additional_aws_accounts") or []),
    }


def build_create_payload(spec: Dict[str, Any]) -> Dict[str, Any]:
    for key in ("region", "availability_zone_ids", "location_name", "location_template_id"):
        if not spec.get(key):
            raise ZtgwError(f"spec field '{key}' is required to create a gateway")
    prov = {
        "locationName": spec["location_name"],
        "locationTemplate": {"id": int(spec["location_template_id"])},
    }
    prov.update({k: v for k, v in mutable_prov_data(spec).items() if v})
    return {
        "name": spec["name"],
        "platform": "AWS",
        "region": spec["region"],
        "awsRegion": _region_code(spec["region"]),
        "availabilityZoneIds": list(spec["availability_zone_ids"]),
        "provData": prov,
    }


# --------------------------------------------------------------------------
# Operations
# --------------------------------------------------------------------------

def find_gateway(c: Client, name: str) -> Optional[Dict[str, Any]]:
    data = c.get("/ztGateway", platform="AWS", search=name, pageSize=1000)
    matches = [g for g in _as_list(data) if g.get("name") == name]
    if len(matches) > 1:
        raise ZtgwError(f"{len(matches)} gateways are named '{name}'; resolve manually")
    if not matches:
        return None
    return c.get(f"/ztGateway/{int(matches[0]['id'])}")


def find_location(c: Client, name: str) -> Optional[Dict[str, Any]]:
    data = c.get("/location", search=name, pageSize=1000)
    matches = [loc for loc in _as_list(data) if loc.get("name") == name]
    return matches[0] if matches else None


def health(gw: Dict[str, Any]) -> str:
    return str(gw.get("healthStatus") or "UNKNOWN").upper()


def activate(c: Client) -> None:
    status, body = c.request("PUT", "/ecAdminActivateStatus/activate", body={})
    state = body.get("orgEditStatus", "") if isinstance(body, dict) else ""
    log(f"activation requested (HTTP {status}{', ' + state if state else ''})")


def check_region_supported(c: Client, region: str) -> None:
    try:
        regions = _as_list(c.get("/ztGateway/supportedRegions", platform="AWS"))
    except ZtgwError as e:
        log(f"WARNING: could not list supported regions ({e}); continuing")
        return
    names = {_norm_region(r.get(k)) for r in regions for k in ("name", "regionName")}
    names.discard("")
    if names and _norm_region(region) not in names:
        raise ZtgwError(f"region {region} is not supported for ZTGW in this tenant "
                        f"(supported: {', '.join(sorted(names))})")


def wait_healthy(c: Client, gw_id: int, timeout: int) -> Dict[str, Any]:
    deadline = c._clock() + timeout
    while True:
        gw = c.get(f"/ztGateway/{gw_id}")
        state = health(gw)
        log(f"gateway {gw_id} health={state}")
        if state == "HEALTHY":
            return gw
        if c._clock() >= deadline:
            raise ZtgwError(f"gateway {gw_id} not HEALTHY after {timeout}s (last: {state}); "
                            "re-run apply once it is healthy - creation is idempotent")
        c._sleep(POLL_INTERVAL)


def cmd_create(c: Client, spec: Dict[str, Any]) -> Dict[str, Any]:
    name = spec["name"]
    timeout = int(spec.get("health_timeout_seconds", 1800))
    gw = find_gateway(c, name)
    if gw:
        if _norm_region(gw.get("region")) != _norm_region(spec.get("region")):
            raise ZtgwError(f"a gateway named '{name}' already exists in region "
                            f"{gw.get('region')}; refusing to adopt it for {spec.get('region')}")
        log(f"adopting existing gateway '{name}' (id {gw['id']})")
        gw_id = int(gw["id"])
    else:
        check_region_supported(c, spec["region"])
        payload = build_create_payload(spec)
        log(f"creating gateway '{name}' in {spec['region']} "
            f"({', '.join(spec['availability_zone_ids'])})")
        try:
            _, created = c.request("POST", "/ztGateway", body=payload)
        except ZtgwError as e:
            if "pending activation" in str(e).lower():
                raise ZtgwError(f"{e}. Another change in the tenant is waiting for "
                                "activation; review it, then run: ztgw.py activate") from None
            # A failed or timed-out POST may still have created the gateway.
            created = find_gateway(c, name)
            if not created:
                raise
            log(f"create did not confirm ({e}), but gateway '{name}' exists; adopting")
        if not isinstance(created, dict) or "id" not in created:
            raise ZtgwError("create returned no gateway id")
        gw_id = int(created["id"])
        log(f"created gateway id {gw_id}")
    gw = wait_healthy(c, gw_id, timeout)
    activate(c)
    return gw


def cmd_update(c: Client, spec: Dict[str, Any]) -> Dict[str, Any]:
    gw = find_gateway(c, spec["name"])
    if not gw:
        raise ZtgwError(f"gateway '{spec['name']}' not found; create it first")
    prov = dict(gw.get("provData") or {})
    current = {
        "accountGroups": sorted(int(x["id"]) for x in prov.get("accountGroups") or []),
        "allowedAccounts": sorted(int(x["id"]) for x in prov.get("allowedAccounts") or []),
        "additionalAwsAccounts": sorted(prov.get("additionalAwsAccounts") or []),
    }
    wanted = mutable_prov_data(spec)
    desired = {
        "accountGroups": [x["id"] for x in wanted["accountGroups"]],
        "allowedAccounts": [x["id"] for x in wanted["allowedAccounts"]],
        "additionalAwsAccounts": wanted["additionalAwsAccounts"],
    }
    if current == desired:
        log("gateway settings already up to date")
        return gw
    prov.update(wanted)
    body = {k: gw[k] for k in ("id", "name", "platform", "region", "availabilityZoneIds") if k in gw}
    body["provData"] = prov
    log(f"updating gateway '{spec['name']}' (id {gw['id']})")
    c.request("PUT", f"/ztGateway/{int(gw['id'])}", body=body)
    activate(c)
    return c.get(f"/ztGateway/{int(gw['id'])}")


def cmd_delete(c: Client, spec: Dict[str, Any]) -> None:
    name = spec["name"]
    timeout = int(spec.get("delete_timeout_seconds", 900))
    gw = find_gateway(c, name)
    if not gw:
        log(f"gateway '{name}' not found (already deleted)")
    else:
        gw_id = int(gw["id"])
        log(f"deleting gateway '{name}' (id {gw_id})")
        c.request("DELETE", f"/ztGateway/{gw_id}", ok_statuses=(200, 202, 204, 404))
        deadline = c._clock() + timeout
        while find_gateway(c, name):
            if c._clock() >= deadline:
                raise ZtgwError(f"gateway {gw_id} still present after {timeout}s")
            c._sleep(POLL_INTERVAL)
        log("gateway deleted")
        activate(c)

    loc_name = spec.get("location_name")
    if spec.get("cleanup_location") and loc_name:
        loc = find_location(c, loc_name)
        if loc:
            log(f"deleting leftover location '{loc_name}' (id {loc['id']})")
            c.request("DELETE", f"/location/{int(loc['id'])}", ok_statuses=(200, 204, 404))
            activate(c)
        else:
            log(f"no leftover location '{loc_name}'")


def summarize(gw: Optional[Dict[str, Any]], loc: Optional[Dict[str, Any]]) -> Dict[str, str]:
    """Flat map of strings, as required by Terraform's external data source."""
    gw = gw or {}
    prov = gw.get("provData") or {}
    return {
        "exists": "true" if gw else "false",
        "id": str(gw.get("id", "")),
        "name": str(gw.get("name", "")),
        "region": str(gw.get("region", "")),
        "health_status": str(gw.get("healthStatus", "")),
        "endpoint_service_name": str(gw.get("endpointServiceName", "")),
        "endpoints_count": str(gw.get("endpointsCount", "")),
        "availability_zone_ids": ",".join(gw.get("availabilityZoneIds") or []),
        "location_name": str(prov.get("locationName") or (loc or {}).get("name", "")),
        "location_id": str((loc or {}).get("id", "")),
    }


def cmd_read(c: Client, query: Dict[str, Any]) -> Dict[str, str]:
    spec = validate_spec({"name": query.get("name", ""),
                          "location_name": query.get("location_name", "")})
    gw = find_gateway(c, spec["name"])
    loc_name = ((gw or {}).get("provData") or {}).get("locationName") or spec.get("location_name")
    loc = find_location(c, loc_name) if gw and loc_name else None
    return summarize(gw, loc)


# --------------------------------------------------------------------------
# Workload Discovery (WDS) onboarding
# --------------------------------------------------------------------------

ROLE_NAME_RE = re.compile(r"^[A-Za-z0-9+=,.@_-]{1,64}$")
EXTERNAL_ID_RE = re.compile(r"^[A-Za-z0-9-]{1,1224}$")


def _load_env_json(var: str) -> Dict[str, Any]:
    raw = os.environ.get(var, "")
    if not raw:
        raise ZtgwError(f"{var} is not set")
    try:
        data = json.loads(raw)
    except ValueError:
        raise ZtgwError(f"{var} is not valid JSON") from None
    if not isinstance(data, dict):
        raise ZtgwError(f"{var} must be a JSON object")
    return data


def _positive_int(data: Dict[str, Any], key: str) -> int:
    try:
        value = int(str(data.get(key, "")))
    except ValueError:
        value = 0
    if value <= 0:
        raise ZtgwError(f"'{key}' must be a positive integer")
    return value


def cmd_wds_settings(c: Client) -> Dict[str, str]:
    data = c.get("/discoveryService/workloadDiscoverySettings")
    if not isinstance(data, dict):
        raise ZtgwError("workloadDiscoverySettings returned no data")
    account = str(data.get("trustedAccountId") or "")
    role = str(data.get("trustedRoleName") or data.get("trustedRole") or "")
    if not AWS_ACCOUNT_RE.match(account) or not role:
        raise ZtgwError("workloadDiscoverySettings did not return a trusted account and role; "
                        "is Workload Discovery enabled for this tenant?")
    arn = role if role.startswith("arn:") else f"arn:aws:iam::{account}:role/{role.lstrip('/')}"
    return {"trusted_account_id": account, "trusted_role_name": role, "trusted_role_arn": arn}


def find_account(c: Client, aws_account_id: str) -> Optional[Dict[str, Any]]:
    matches = [a for a in _as_list(c.get("/publicCloudInfo"))
               if str((a.get("accountDetails") or {}).get("awsAccountId", "")) == aws_account_id]
    if len(matches) > 1:
        raise ZtgwError(f"{len(matches)} Partner Integrations entries for AWS account "
                        f"{aws_account_id}; remove the duplicates in the portal")
    return matches[0] if matches else None


def _account_external_id(acct: Dict[str, Any]) -> str:
    return str(acct.get("externalId") or (acct.get("accountDetails") or {}).get("externalId") or "")


def validate_account_spec(spec: Dict[str, Any]) -> Dict[str, Any]:
    acct = str(spec.get("aws_account_id", ""))
    if not AWS_ACCOUNT_RE.match(acct):
        raise ZtgwError(f"invalid aws_account_id {acct!r}")
    if not NAME_RE.match(str(spec.get("name", ""))):
        raise ZtgwError(f"invalid account name {spec.get('name')!r}")
    if not ROLE_NAME_RE.match(str(spec.get("role_name", ""))):
        raise ZtgwError(f"invalid role_name {spec.get('role_name')!r}")
    ext = spec.get("external_id") or ""
    if ext and not EXTERNAL_ID_RE.match(str(ext)):
        raise ZtgwError("invalid external_id (allowed: letters, digits, '-')")
    regions = spec.get("regions") or []
    if not isinstance(regions, list) or not regions or \
            not all(isinstance(r, str) and REGION_RE.match(r) for r in regions):
        raise ZtgwError("regions must be a non-empty list of AWS region names")
    return spec


def _select_regions(c: Client, wanted: List[str]) -> List[Dict[str, Any]]:
    available = _as_list(c.get("/publicCloudInfo/supportedRegions"))
    chosen, missing = [], []
    for region in wanted:
        hit = next((r for r in available
                    if _norm_region(region) in {_norm_region(r.get(k)) for k in ("name", "regionName")}),
                   None)
        (chosen.append(hit) if hit else missing.append(region))
    if missing:
        names = sorted({str(r.get("regionName") or r.get("name")) for r in available})
        raise ZtgwError(f"region(s) {', '.join(missing)} not supported for discovery "
                        f"(supported: {', '.join(names) or 'none listed'})")
    return chosen


ACCOUNT_APPEAR_TIMEOUT = 600


def cmd_account_register(c: Client, spec: Dict[str, Any]) -> Dict[str, Any]:
    validate_account_spec(spec)
    aws_id = str(spec["aws_account_id"])
    wanted_ext = str(spec.get("external_id") or "")
    existing = find_account(c, aws_id)
    if existing:
        have = _account_external_id(existing)
        if wanted_ext and have and have != wanted_ext:
            raise ZtgwError(f"AWS account {aws_id} is already registered (id {existing.get('id')}) "
                            "with a different external ID; delete it in the portal or set "
                            "external_id to the registered value")
        log(f"AWS account {aws_id} already registered (id {existing.get('id')}); adopting")
        return existing

    regions = _select_regions(c, list(spec["regions"]))
    role = str(spec["role_name"])
    ext = wanted_ext
    if not ext:
        gen = c.request("POST", "/publicCloudInfo/generateExternalId",
                        body={"awsAccountId": aws_id, "awsRoleName": role})[1]
        ext = _account_external_id(gen) if isinstance(gen, dict) else ""
        if not EXTERNAL_ID_RE.match(ext):
            raise ZtgwError("generateExternalId returned no usable external ID")
    payload = {
        "name": spec["name"], "cloudType": "AWS", "externalId": ext,
        "accountDetails": {"awsAccountId": aws_id, "awsRoleName": role, "externalId": ext},
        "supportedRegions": regions,
    }
    log(f"registering AWS account {aws_id} as '{spec['name']}' (can take several minutes)")
    try:
        created = c.request("POST", "/publicCloudInfo", body=payload)[1]
        if isinstance(created, dict) and created.get("id"):
            return created
    except ZtgwError as e:
        # The create call is slow and may time out (or 5xx) although the
        # account is created; look it up before declaring failure.
        log(f"create did not confirm ({e}); checking whether the account was created")
    deadline = c._clock() + ACCOUNT_APPEAR_TIMEOUT
    while True:
        found = find_account(c, aws_id)
        if found:
            return found
        if c._clock() >= deadline:
            raise ZtgwError(f"AWS account {aws_id} was not registered")
        c._sleep(POLL_INTERVAL)


def cmd_account_read(c: Client, query: Dict[str, Any]) -> Dict[str, str]:
    aws_id = str(query.get("aws_account_id", ""))
    if not AWS_ACCOUNT_RE.match(aws_id):
        raise ZtgwError(f"account-read: invalid aws_account_id {aws_id!r}")
    acct = find_account(c, aws_id)
    if not acct:
        return {"exists": "false", "id": "", "external_id": "", "name": "", "event_bus_name": ""}
    details = acct.get("accountDetails") or {}
    return {"exists": "true", "id": str(acct.get("id", "")),
            "external_id": _account_external_id(acct), "name": str(acct.get("name", "")),
            # Zscaler's per-org bus, as an ARN template with a <REGION> placeholder:
            # arn:aws:events:<REGION>:175726779870:event-bus/zscaler-bus-<org>-<cloud>
            "event_bus_name": str(details.get("eventBusName") or "")}


def cmd_account_delete(c: Client, spec: Dict[str, Any]) -> None:
    aws_id = str(spec.get("aws_account_id", ""))
    if not AWS_ACCOUNT_RE.match(aws_id):
        raise ZtgwError(f"invalid aws_account_id {aws_id!r}")
    acct = find_account(c, aws_id)
    if not acct:
        log(f"AWS account {aws_id} not registered; nothing to delete")
        return
    log(f"deleting Partner Integrations account {acct.get('id')} ({aws_id})")
    c.request("DELETE", f"/publicCloudInfo/{int(acct['id'])}", ok_statuses=(200, 204, 404))
    activate(c)


def _permission_denials(result: Any) -> List[str]:
    """Checks that are not 'Allowed' in a permissions response.

    The endpoint answers HTTP 200 for both outcomes, e.g.
    {"status": {"assumeRole": "Allowed", "ec2:DescribeVpcs": "Denied"}}.
    """
    status = result.get("status") if isinstance(result, dict) else None
    if not isinstance(status, dict) or not status:
        return ["no permission status in response"]
    denied = [f"{k}={v}" for k, v in status.items() if v != "Allowed"]
    if status.get("assumeRole") != "Allowed" and not any(d.startswith("assumeRole=") for d in denied):
        denied.insert(0, "assumeRole=missing")
    return denied


def cmd_wds_verify(c: Client, spec: Dict[str, Any]) -> None:
    account_id = _positive_int(spec, "public_cloud_account_id")
    role = str(spec.get("role_name", ""))
    external_id = str(spec.get("external_id", ""))
    if not ROLE_NAME_RE.match(role):
        raise ZtgwError(f"invalid role_name {role!r}")
    if not EXTERNAL_ID_RE.match(external_id):
        raise ZtgwError("invalid external_id")
    timeout = int(spec.get("timeout_seconds", 300))
    deadline = c._clock() + timeout
    body = {"discoveryRole": role, "externalId": external_id}
    while True:
        try:
            _, result = c.request("PUT", f"/discoveryService/{account_id}/permissions", body=body)
            denied = _permission_denials(result)
        except ZtgwError as e:
            denied = [str(e)]
        if not denied:
            log(f"discovery role '{role}' verified for public cloud account {account_id}")
            return
        if c._clock() >= deadline:
            raise ZtgwError(f"discovery role verification failed after {timeout}s: "
                            f"{', '.join(denied)}")
        log(f"not yet allowed ({', '.join(denied)}); IAM may still be propagating, retrying")
        c._sleep(POLL_INTERVAL)


def _group_change(c: Client, spec: Dict[str, Any], add: bool) -> None:
    group_id = _positive_int(spec, "group_id")
    account_id = _positive_int(spec, "public_cloud_account_id")
    _, group = c.request("GET", f"/accountGroups/{group_id}", ok_statuses=(200, 404))
    if not isinstance(group, dict) or not group.get("id"):
        if add:
            raise ZtgwError(f"account group {group_id} not found")
        log(f"account group {group_id} not found; nothing to remove")
        return
    members = [m for m in group.get("publicCloudAccounts") or [] if isinstance(m, dict)]
    present = any(int(m.get("id", 0)) == account_id for m in members)
    if add == present:
        log(f"account {account_id} already {'in' if add else 'absent from'} group {group_id}")
        return
    if add:
        members.append({"id": account_id})
    else:
        members = [m for m in members if int(m.get("id", 0)) != account_id]
    body = {k: group[k] for k in ("id", "name", "description", "cloudType",
                                  "cloudConnectorGroups") if k in group}
    body["publicCloudAccounts"] = [{"id": int(m["id"])} for m in members]
    log(f"{'adding' if add else 'removing'} account {account_id} "
        f"{'to' if add else 'from'} group {group_id}")
    c.request("PUT", f"/accountGroups/{group_id}", body=body)
    activate(c)


# --------------------------------------------------------------------------
# CLI
# --------------------------------------------------------------------------

COMMANDS = ("create", "update", "delete", "read", "activate", "regions",
            "wds-settings", "wds-verify", "group-add", "group-remove",
            "account-register", "account-read", "account-delete")
USAGE = "usage: ztgw.py {" + "|".join(COMMANDS) + "}"


def main(argv: List[str], client_factory: Callable[[], Client] = Client) -> int:
    if len(argv) != 2 or argv[1] not in COMMANDS:
        print(USAGE, file=sys.stderr)
        return 2
    cmd = argv[1]
    try:
        # Parse all input before authenticating, so bad input fails fast.
        query: Dict[str, Any] = {}
        spec: Dict[str, Any] = {}
        if cmd in ("read", "wds-settings", "account-read"):
            try:
                query = json.loads(sys.stdin.read() or "{}")
            except ValueError:
                raise ZtgwError(f"{cmd}: stdin is not valid JSON") from None
        elif cmd in ("create", "update", "delete"):
            spec = load_spec()
        elif cmd == "wds-verify":
            spec = _load_env_json("ZTGW_WDS")
        elif cmd in ("group-add", "group-remove"):
            spec = _load_env_json("ZTGW_GROUP")
        elif cmd == "account-register":
            spec = validate_account_spec(_load_env_json("ZTGW_ACCOUNT"))
        elif cmd == "account-delete":
            spec = _load_env_json("ZTGW_ACCOUNT")

        c = client_factory()
        try:
            if cmd == "read":
                print(json.dumps(cmd_read(c, query)))
            elif cmd == "wds-settings":
                print(json.dumps(cmd_wds_settings(c)))
            elif cmd == "create":
                gw = cmd_create(c, spec)
                log(f"gateway ready: endpoint service {gw.get('endpointServiceName', '?')}")
            elif cmd == "update":
                cmd_update(c, spec)
            elif cmd == "delete":
                cmd_delete(c, spec)
            elif cmd == "activate":
                activate(c)
            elif cmd == "regions":
                for r in _as_list(c.get("/ztGateway/supportedRegions", platform="AWS")):
                    print(r.get("regionName") or r.get("name"))
            elif cmd == "wds-verify":
                cmd_wds_verify(c, spec)
            elif cmd == "group-add":
                _group_change(c, spec, add=True)
            elif cmd == "group-remove":
                _group_change(c, spec, add=False)
            elif cmd == "account-register":
                acct = cmd_account_register(c, spec)
                log(f"account registered: id {acct.get('id')}")
            elif cmd == "account-read":
                print(json.dumps(cmd_account_read(c, query)))
            elif cmd == "account-delete":
                cmd_account_delete(c, spec)
        finally:
            c.close()
    except ZtgwError as e:
        print(f"[ztgw] ERROR: {e}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
