"""Unit tests for scripts/ztgw/ztgw.py.

Run:  python3 -I -m unittest discover -s tests/python -v
(scripts/qa.sh step "python" does this.)

A fake transport emulates the Cloud & Branch Connector API in memory, so no
network or tenant is needed.
"""

import io
import json
import os
import sys
import unittest
from contextlib import redirect_stderr, redirect_stdout
from pathlib import Path
from unittest import mock
from urllib.parse import parse_qs, urlsplit

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "scripts" / "ztgw"))
import ztgw  # noqa: E402

ONEAPI_ENV = {
    "ZSCALER_USE_LEGACY_CLIENT": "false",
    "ZSCALER_CLIENT_ID": "cid",
    "ZSCALER_CLIENT_SECRET": "top-secret-value",
    "ZSCALER_VANITY_DOMAIN": "acme",
}
LEGACY_ENV = {
    "ZSCALER_USE_LEGACY_CLIENT": "true",
    "ZTC_USERNAME": "admin@acme.com",
    "ZTC_PASSWORD": "legacy-password",
    "ZTC_API_KEY": "abcdefghijklmnop",
    "ZTC_CLOUD": "zscalerthree",
}
SPEC = {
    "name": "ztgw-zs2-us-west-2",
    "region": "us-west-2",
    "availability_zone_ids": ["usw2-az1", "usw2-az2", "usw2-az3"],
    "location_name": "ztgw-zs2-us-west-2-loc",
    "location_template_id": 77,
    "account_group_ids": [500],
    "allowed_account_ids": [],
    "additional_aws_accounts": ["123456789012"],
    "health_timeout_seconds": 120,
    "cleanup_location": True,
}


class FakeApi:
    """In-memory Cloud & Branch Connector API."""

    def __init__(self, health_sequence=("INIT", "HEALTHY")):
        self.calls = []
        self.gateways = {}
        self.locations = {}
        self.next_id = 1000
        self.health_sequence = list(health_sequence)
        self.fail_next = []          # list of (status, body) injected responses
        self.activations = 0
        self.regions = [{"id": 1, "name": "US_WEST_2", "regionName": "us-west-2"}]

    def __call__(self, method, url, headers, body):
        self.calls.append((method, url, dict(headers), body))
        if self.fail_next:
            status, payload = self.fail_next.pop(0)
            return status, {}, json.dumps(payload).encode()
        parts = urlsplit(url)
        path = parts.path
        query = {k: v[0] for k, v in parse_qs(parts.query).items()}

        if path.endswith("/oauth2/v1/token"):
            return 200, {}, json.dumps({"access_token": "tok-123", "expires_in": 3600}).encode()
        if path.endswith("/auth") and method == "POST":
            return 200, {"Set-Cookie": "JSESSIONID=sess-9; Path=/; Secure"}, b"{}"
        if path.endswith("/auth") and method == "DELETE":
            return 204, {}, b""

        tail = path.split("/api/v1", 1)[1]
        if tail == "/ztGateway/supportedRegions":
            return 200, {}, json.dumps(self.regions).encode()
        if tail == "/ztGateway" and method == "GET":
            found = [g for g in self.gateways.values() if query.get("search", "") in g["name"]]
            return 200, {}, json.dumps(found).encode()
        if tail == "/ztGateway" and method == "POST":
            payload = json.loads(body)
            gid = self.next_id
            self.next_id += 1
            self.gateways[gid] = {
                "id": gid, "name": payload["name"], "platform": "AWS",
                "region": payload["region"], "availabilityZoneIds": payload["availabilityZoneIds"],
                "provData": payload["provData"], "healthStatus": "INIT",
                "endpointServiceName": f"com.amazonaws.vpce.us-west-2.vpce-svc-{gid}",
                "endpointsCount": "0",
            }
            loc_id = 9000 + gid
            self.locations[loc_id] = {"id": loc_id, "name": payload["provData"]["locationName"]}
            return 200, {}, json.dumps({"id": gid}).encode()
        if tail.startswith("/ztGateway/"):
            gid = int(tail.rsplit("/", 1)[1])
            if gid not in self.gateways:
                return 404, {}, b'{"code":"RESOURCE_NOT_FOUND"}'
            if method == "GET":
                gw = self.gateways[gid]
                if self.health_sequence:
                    gw["healthStatus"] = self.health_sequence.pop(0)
                return 200, {}, json.dumps(gw).encode()
            if method == "PUT":
                self.gateways[gid]["provData"] = json.loads(body)["provData"]
                return 200, {}, b"{}"
            if method == "DELETE":
                del self.gateways[gid]
                return 204, {}, b""
        if tail == "/location" and method == "GET":
            found = [loc for loc in self.locations.values() if query.get("search", "") in loc["name"]]
            return 200, {}, json.dumps(found).encode()
        if tail.startswith("/location/") and method == "DELETE":
            self.locations.pop(int(tail.rsplit("/", 1)[1]), None)
            return 204, {}, b""
        if tail == "/ecAdminActivateStatus/activate" and method == "PUT":
            self.activations += 1
            return 200, {}, json.dumps({"orgEditStatus": "ACTIVE"}).encode()
        return 500, {}, b'{"message":"unexpected call in fake"}'

    def paths(self, method=None):
        return [urlsplit(u).path for m, u, _, _ in self.calls if method in (None, m)]


class Clock:
    def __init__(self):
        self.now = 1_700_000_000.0

    def time(self):
        return self.now

    def sleep(self, seconds):
        self.now += seconds


def make_client(env, api):
    clock = Clock()
    with mock.patch.dict(os.environ, env, clear=True):
        return ztgw.Client(transport=api, sleep=clock.sleep, clock=clock.time)


class ObfuscationTest(unittest.TestCase):
    def test_known_vector(self):
        # high=123456 -> seed[1..6]="bcdefg"; low=61728 -> "061728" -> seed[i+2]="cidjek"
        self.assertEqual(ztgw.obfuscate_api_key("abcdefghijklmnop", "1700000123456"),
                         "bcdefgcidjek")

    def test_short_key_rejected(self):
        with self.assertRaises(ztgw.ZtgwError):
            ztgw.obfuscate_api_key("short", "1700000123456")


class ClientConfigTest(unittest.TestCase):
    def test_oneapi_production_urls(self):
        c = make_client(ONEAPI_ENV, FakeApi())
        self.assertFalse(c.legacy)
        self.assertEqual(c.token_url, "https://acme.zslogin.net/oauth2/v1/token")
        self.assertEqual(c.base_url, "https://api.zsapi.net/ztw/api/v1")

    def test_oneapi_beta_urls(self):
        c = make_client({**ONEAPI_ENV, "ZSCALER_CLOUD": "beta"}, FakeApi())
        self.assertEqual(c.token_url, "https://acme.zsloginbeta.net/oauth2/v1/token")
        self.assertEqual(c.base_url, "https://api.beta.zsapi.net/ztw/api/v1")

    def test_legacy_urls(self):
        c = make_client(LEGACY_ENV, FakeApi())
        self.assertTrue(c.legacy)
        self.assertEqual(c.base_url, "https://connector.zscalerthree.net/api/v1")

    def test_missing_credentials(self):
        env = dict(ONEAPI_ENV)
        del env["ZSCALER_CLIENT_SECRET"]
        with self.assertRaisesRegex(ztgw.ZtgwError, "ZSCALER_CLIENT_SECRET"):
            make_client(env, FakeApi())

    def test_private_key_only_is_explained(self):
        env = dict(ONEAPI_ENV)
        del env["ZSCALER_CLIENT_SECRET"]
        env["ZSCALER_PRIVATE_KEY"] = "-----BEGIN"
        with self.assertRaisesRegex(ztgw.ZtgwError, "client-secret auth only"):
            make_client(env, FakeApi())

    def test_unknown_legacy_cloud(self):
        with self.assertRaises(ztgw.ZtgwError):
            make_client({**LEGACY_ENV, "ZTC_CLOUD": "evil.example.com/x"}, FakeApi())

    def test_bad_vanity_domain(self):
        with self.assertRaises(ztgw.ZtgwError):
            make_client({**ONEAPI_ENV, "ZSCALER_VANITY_DOMAIN": "acme.evil.com/"}, FakeApi())

    def test_gov_rejected(self):
        with self.assertRaises(ztgw.ZtgwError):
            make_client({**ONEAPI_ENV, "ZSCALER_CLOUD": "gov"}, FakeApi())

    def test_non_https_refused(self):
        with self.assertRaises(ztgw.ZtgwError):
            ztgw.urllib_transport("GET", "http://api.zsapi.net/x", {}, None)


class AuthTest(unittest.TestCase):
    def test_oneapi_bearer_and_audience(self):
        api = FakeApi()
        c = make_client(ONEAPI_ENV, api)
        c.get("/ztGateway")
        token_call = api.calls[0]
        self.assertIn(b"audience=https%3A%2F%2Fapi.zscaler.com", token_call[3])
        self.assertIn(b"grant_type=client_credentials", token_call[3])
        self.assertEqual(api.calls[1][2]["Authorization"], "Bearer tok-123")

    def test_token_reused(self):
        api = FakeApi()
        c = make_client(ONEAPI_ENV, api)
        c.get("/ztGateway")
        c.get("/ztGateway")
        self.assertEqual(sum(1 for p in api.paths() if p.endswith("/token")), 1)

    def test_legacy_session_cookie_and_logout(self):
        api = FakeApi()
        c = make_client(LEGACY_ENV, api)
        c.get("/ztGateway")
        auth_body = json.loads(api.calls[0][3])
        self.assertEqual(set(auth_body), {"username", "password", "apiKey", "timestamp"})
        self.assertNotEqual(auth_body["apiKey"], LEGACY_ENV["ZTC_API_KEY"])
        self.assertEqual(api.calls[1][2]["Cookie"], "JSESSIONID=sess-9")
        c.close()
        self.assertEqual(api.calls[-1][0], "DELETE")

    def test_401_triggers_one_reauth(self):
        api = FakeApi()
        c = make_client(ONEAPI_ENV, api)
        c.get("/ztGateway")
        api.fail_next = [(401, {"message": "expired"})]
        c.get("/ztGateway")
        self.assertEqual(sum(1 for p in api.paths() if p.endswith("/token")), 2)

    def test_auth_failure_message_has_no_secret(self):
        api = FakeApi()
        api.fail_next = [(401, {"message": "bad"})]
        c = make_client(ONEAPI_ENV, api)
        with self.assertRaises(ztgw.ZtgwError) as ctx:
            c.get("/ztGateway")
        self.assertNotIn("top-secret-value", str(ctx.exception))


class RetryTest(unittest.TestCase):
    def test_429_retried(self):
        api = FakeApi()
        c = make_client(ONEAPI_ENV, api)
        c.get("/ztGateway")
        api.fail_next = [(429, {}), (503, {})]
        self.assertEqual(c.get("/ztGateway"), [])

    def test_gives_up(self):
        api = FakeApi()
        c = make_client(ONEAPI_ENV, api)
        c.get("/ztGateway")
        api.fail_next = [(500, {})] * ztgw.MAX_RETRIES
        with self.assertRaisesRegex(ztgw.ZtgwError, "giving up"):
            c.get("/ztGateway")

    def test_api_error_surfaces_code(self):
        api = FakeApi()
        c = make_client(ONEAPI_ENV, api)
        c.get("/ztGateway")
        api.fail_next = [(400, {"code": "INVALID_INPUT_ARGUMENT", "message": "bad name"})]
        with self.assertRaisesRegex(ztgw.ZtgwError, "INVALID_INPUT_ARGUMENT bad name"):
            c.request("POST", "/ztGateway", body={})


class SpecTest(unittest.TestCase):
    def test_valid(self):
        self.assertEqual(ztgw.validate_spec(dict(SPEC))["name"], SPEC["name"])

    def test_invalid_values(self):
        bad = [
            {"name": ""}, {"name": "x;rm -rf"}, {"name": "ok", "region": "US_WEST_2"},
            {"name": "ok", "availability_zone_ids": ["us-west-2a"]},
            {"name": "ok", "additional_aws_accounts": ["1234"]},
            {"name": "ok", "account_group_ids": ["5"]},
            {"name": "ok", "account_group_ids": [True]},
        ]
        for spec in bad:
            with self.subTest(spec=spec), self.assertRaises(ztgw.ZtgwError):
                ztgw.validate_spec(spec)

    def test_create_payload(self):
        p = ztgw.build_create_payload(SPEC)
        self.assertEqual(p["platform"], "AWS")
        self.assertEqual(p["region"], "us-west-2")
        self.assertEqual(p["awsRegion"], "US_WEST_2")
        self.assertEqual(p["availabilityZoneIds"], ["usw2-az1", "usw2-az2", "usw2-az3"])
        self.assertEqual(p["provData"]["locationTemplate"], {"id": 77})
        self.assertEqual(p["provData"]["accountGroups"], [{"id": 500}])
        self.assertNotIn("allowedAccounts", p["provData"])  # empty lists omitted
        self.assertEqual(p["provData"]["additionalAwsAccounts"], ["123456789012"])

    def test_create_payload_requires_fields(self):
        with self.assertRaisesRegex(ztgw.ZtgwError, "location_template_id"):
            ztgw.build_create_payload({**SPEC, "location_template_id": None})


class CreateTest(unittest.TestCase):
    def test_create_polls_and_activates(self):
        api = FakeApi(health_sequence=["INIT", "INIT", "HEALTHY"])
        c = make_client(ONEAPI_ENV, api)
        gw = ztgw.cmd_create(c, dict(SPEC))
        self.assertEqual(gw["healthStatus"], "HEALTHY")
        self.assertEqual(api.activations, 1)
        self.assertEqual(len(api.gateways), 1)

    def test_create_is_idempotent(self):
        api = FakeApi(health_sequence=[])
        c = make_client(ONEAPI_ENV, api)
        api.health_sequence = ["HEALTHY"] * 10
        ztgw.cmd_create(c, dict(SPEC))
        ztgw.cmd_create(c, dict(SPEC))
        self.assertEqual(len(api.gateways), 1)
        self.assertEqual(api.paths("POST").count("/ztw/api/v1/ztGateway"), 1)

    def test_adopt_refuses_region_mismatch(self):
        api = FakeApi(health_sequence=["HEALTHY"] * 10)
        c = make_client(ONEAPI_ENV, api)
        ztgw.cmd_create(c, dict(SPEC))
        api.regions.append({"id": 2, "name": "US_EAST_1", "regionName": "us-east-1"})
        with self.assertRaisesRegex(ztgw.ZtgwError, "refusing to adopt"):
            ztgw.cmd_create(c, {**SPEC, "region": "us-east-1"})

    def test_unsupported_region(self):
        api = FakeApi()
        c = make_client(ONEAPI_ENV, api)
        with self.assertRaisesRegex(ztgw.ZtgwError, "not supported"):
            ztgw.cmd_create(c, {**SPEC, "region": "eu-west-1"})
        self.assertNotIn("/ztw/api/v1/ztGateway", api.paths("POST"))

    def test_health_timeout(self):
        api = FakeApi(health_sequence=["INIT"] * 100)
        c = make_client(ONEAPI_ENV, api)
        with self.assertRaisesRegex(ztgw.ZtgwError, "not HEALTHY after 120s"):
            ztgw.cmd_create(c, dict(SPEC))
        self.assertEqual(api.activations, 0)

    def test_pending_activation_explained(self):
        api = FakeApi()
        c = make_client(ONEAPI_ENV, api)
        c.get("/ztGateway")
        api.fail_next = [(200, []), (200, api.regions),
                         (400, {"code": "INVALID_OPERATION",
                                "message": "Cannot create Zero Trust Gateway while there are "
                                           "pending activation changes."})]
        with self.assertRaisesRegex(ztgw.ZtgwError, "ztgw.py activate"):
            ztgw.cmd_create(c, dict(SPEC))

    def test_legacy_create(self):
        api = FakeApi(health_sequence=["HEALTHY"])
        c = make_client(LEGACY_ENV, api)
        ztgw.cmd_create(c, dict(SPEC))
        self.assertTrue(all(u.startswith("https://connector.zscalerthree.net/api/v1")
                            for _, u, _, _ in api.calls))


class UpdateDeleteTest(unittest.TestCase):
    def setUp(self):
        self.api = FakeApi(health_sequence=["HEALTHY"] * 50)
        self.c = make_client(ONEAPI_ENV, self.api)
        ztgw.cmd_create(self.c, dict(SPEC))
        self.api.activations = 0

    def test_update_noop(self):
        ztgw.cmd_update(self.c, dict(SPEC))
        self.assertNotIn("PUT", [m for m, u, _, _ in self.api.calls if "/ztGateway/" in u])
        self.assertEqual(self.api.activations, 0)

    def test_update_changes_groups(self):
        ztgw.cmd_update(self.c, {**SPEC, "account_group_ids": [500, 600]})
        gw = next(iter(self.api.gateways.values()))
        self.assertEqual(gw["provData"]["accountGroups"], [{"id": 500}, {"id": 600}])
        self.assertEqual(gw["provData"]["locationName"], SPEC["location_name"])
        self.assertEqual(self.api.activations, 1)

    def test_update_missing_gateway(self):
        with self.assertRaisesRegex(ztgw.ZtgwError, "not found"):
            ztgw.cmd_update(self.c, {**SPEC, "name": "other"})

    def test_delete_cleans_location_and_activates(self):
        ztgw.cmd_delete(self.c, dict(SPEC))
        self.assertEqual(self.api.gateways, {})
        self.assertEqual(self.api.locations, {})
        self.assertEqual(self.api.activations, 2)

    def test_delete_without_cleanup_keeps_location(self):
        ztgw.cmd_delete(self.c, {**SPEC, "cleanup_location": False})
        self.assertEqual(len(self.api.locations), 1)

    def test_delete_absent_is_ok(self):
        ztgw.cmd_delete(self.c, dict(SPEC))
        ztgw.cmd_delete(self.c, dict(SPEC))  # second run: nothing left, no error

    def test_read(self):
        out = ztgw.cmd_read(self.c, {"name": SPEC["name"]})
        self.assertEqual(out["exists"], "true")
        self.assertEqual(out["health_status"], "HEALTHY")
        self.assertTrue(out["endpoint_service_name"].startswith("com.amazonaws.vpce"))
        self.assertEqual(out["location_name"], SPEC["location_name"])
        self.assertTrue(out["location_id"].isdigit())
        self.assertTrue(all(isinstance(v, str) for v in out.values()))

    def test_read_absent(self):
        out = ztgw.cmd_read(self.c, {"name": "nope"})
        self.assertEqual(out["exists"], "false")
        self.assertEqual(out["endpoint_service_name"], "")


class CliTest(unittest.TestCase):
    def run_main(self, argv, env, stdin="", api=None):
        api = api or FakeApi(health_sequence=["HEALTHY"] * 10)
        out, err = io.StringIO(), io.StringIO()
        with mock.patch.dict(os.environ, env, clear=True), \
                mock.patch.object(sys, "stdin", io.StringIO(stdin)), \
                redirect_stdout(out), redirect_stderr(err):
            clock = Clock()
            rc = ztgw.main(argv, client_factory=lambda: ztgw.Client(
                transport=api, sleep=clock.sleep, clock=clock.time))
        return rc, out.getvalue(), err.getvalue()

    def test_usage(self):
        rc, _, err = self.run_main(["ztgw.py"], ONEAPI_ENV)
        self.assertEqual(rc, 2)
        self.assertIn("usage", err)

    def test_create_then_read(self):
        api = FakeApi(health_sequence=["HEALTHY"] * 10)
        rc, out, err = self.run_main(["ztgw.py", "create"],
                                     {**ONEAPI_ENV, "ZTGW_SPEC": json.dumps(SPEC)}, api=api)
        self.assertEqual(rc, 0, err)
        self.assertEqual(out, "")  # create prints nothing on stdout
        rc, out, err = self.run_main(["ztgw.py", "read"], ONEAPI_ENV,
                                     stdin=json.dumps({"name": SPEC["name"]}), api=api)
        self.assertEqual(rc, 0, err)
        self.assertEqual(json.loads(out)["exists"], "true")

    def test_secrets_never_printed(self):
        api = FakeApi()
        api.fail_next = [(403, {"message": "forbidden"})]
        rc, out, err = self.run_main(["ztgw.py", "create"],
                                     {**ONEAPI_ENV, "ZTGW_SPEC": json.dumps(SPEC)}, api=api)
        self.assertEqual(rc, 1)
        for secret in ("top-secret-value", "tok-123"):
            self.assertNotIn(secret, out + err)

    def test_bad_spec_json(self):
        rc, _, err = self.run_main(["ztgw.py", "create"], {**ONEAPI_ENV, "ZTGW_SPEC": "{"})
        self.assertEqual(rc, 1)
        self.assertIn("not valid JSON", err)

    def test_missing_spec(self):
        rc, _, err = self.run_main(["ztgw.py", "delete"], ONEAPI_ENV)
        self.assertEqual(rc, 1)
        self.assertIn("ZTGW_SPEC is not set", err)

    def test_regions(self):
        rc, out, _ = self.run_main(["ztgw.py", "regions"], LEGACY_ENV)
        self.assertEqual(rc, 0)
        self.assertEqual(out.strip(), "us-west-2")


if __name__ == "__main__":
    unittest.main()
