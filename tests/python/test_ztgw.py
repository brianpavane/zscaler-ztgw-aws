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
        self.wds_settings = {"trustedAccountId": "644370868001",
                             "trustedRoleName": "ZscalerTagDiscoveryRole"}
        self.groups = {500: {"id": 500, "name": "consumers", "cloudType": "AWS",
                             "publicCloudAccounts": [{"id": 1, "name": "existing"}]}}
        self.permission_failures = 0
        self.verified = []
        self.accounts = {}
        self.cloud_regions = [{"id": 11, "name": "US_WEST_2", "regionName": "us-west-2",
                               "cloudType": "AWS"},
                              {"id": 12, "name": "US_EAST_1", "regionName": "us-east-1",
                               "cloudType": "AWS"}]
        self.account_create_times_out = False
        self.account_deletes = 0

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
        if tail == "/discoveryService/workloadDiscoverySettings":
            return 200, {}, json.dumps(self.wds_settings).encode()
        if tail.startswith("/discoveryService/") and tail.endswith("/permissions"):
            # Real shape (zscaler-partner-integ-external-id): HTTP 200 for
            # both outcomes, per-check status values.
            if self.permission_failures > 0:
                self.permission_failures -= 1
                return 200, {}, b'{"status":{"assumeRole":"Denied"}}'
            self.verified.append((tail.split("/")[2], json.loads(body)))
            return 200, {}, b'{"status":{"assumeRole":"Allowed","ec2:DescribeVpcs":"Allowed"}}'
        if tail == "/publicCloudInfo/supportedRegions":
            return 200, {}, json.dumps(self.cloud_regions).encode()
        if tail == "/publicCloudInfo/generateExternalId" and method == "POST":
            req = json.loads(body)
            return 200, {}, json.dumps({**req, "externalId": "gen-" + req["awsAccountId"]}).encode()
        if tail == "/publicCloudInfo" and method == "GET":
            return 200, {}, json.dumps(list(self.accounts.values())).encode()
        if tail == "/publicCloudInfo" and method == "POST":
            req = json.loads(body)
            self.next_id += 1
            self.accounts[self.next_id] = {**req, "id": self.next_id}
            if self.account_create_times_out:
                return 504, {}, b"gateway timeout"
            return 200, {}, json.dumps(self.accounts[self.next_id]).encode()
        if tail.startswith("/publicCloudInfo/") and method == "DELETE":
            self.account_deletes += 1
            self.accounts.pop(int(tail.rsplit("/", 1)[1]), None)
            return 204, {}, b""
        if tail.startswith("/accountGroups/"):
            gid = int(tail.rsplit("/", 1)[1])
            if gid not in self.groups:
                return 404, {}, b'{"code":"RESOURCE_NOT_FOUND"}'
            if method == "GET":
                return 200, {}, json.dumps(self.groups[gid]).encode()
            if method == "PUT":
                self.groups[gid] = json.loads(body)
                return 200, {}, body
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


PRODUCTION_CLOUDS = ("zscaler", "zscalerone", "zscalertwo", "zscalerthree", "zscloud")


class ProductionCloudTest(unittest.TestCase):
    def test_legacy_base_url_for_every_production_cloud(self):
        for cloud in PRODUCTION_CLOUDS:
            with self.subTest(cloud=cloud):
                c = make_client({**LEGACY_ENV, "ZTC_CLOUD": cloud}, FakeApi())
                self.assertEqual(c.base_url, f"https://connector.{cloud}.net/api/v1")

    def test_oneapi_production_needs_no_cloud(self):
        c = make_client({**ONEAPI_ENV, "ZSCALER_CLOUD": ""}, FakeApi())
        self.assertEqual(c.base_url, "https://api.zsapi.net/ztw/api/v1")


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

    def test_post_not_retried_on_5xx(self):
        api = FakeApi()
        c = make_client(ONEAPI_ENV, api)
        c.get("/ztGateway")
        api.fail_next = [(503, {})]
        with self.assertRaisesRegex(ztgw.ZtgwError, "HTTP 503"):
            c.request("POST", "/ztGateway", body={})
        self.assertEqual(api.paths("POST").count("/ztw/api/v1/ztGateway"), 1)

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


class CreateFailureTest(unittest.TestCase):
    def test_failed_post_is_not_resent(self):
        api = FakeApi(health_sequence=["HEALTHY"])
        c = make_client(ONEAPI_ENV, api)
        real = api.__call__
        posts = []

        def failing(method, url, headers, body):
            if method == "POST" and url.endswith("/ztGateway"):
                posts.append(url)
                return 500, {}, b"internal error"  # not created
            return real(method, url, headers, body)

        c._transport = failing
        with self.assertRaisesRegex(ztgw.ZtgwError, "HTTP 500"):
            ztgw.cmd_create(c, dict(SPEC))
        self.assertEqual(len(posts), 1)
        self.assertEqual(api.gateways, {})

    def test_created_despite_error_is_adopted(self):
        api = FakeApi(health_sequence=["HEALTHY"])
        c = make_client(ONEAPI_ENV, api)
        real = api.__call__

        def flaky(method, url, headers, body):
            status, h, raw = real(method, url, headers, body)
            if method == "POST" and url.endswith("/ztGateway"):
                return 504, {}, b"gateway timeout"  # created, but not confirmed
            return status, h, raw

        c._transport = flaky
        gw = ztgw.cmd_create(c, dict(SPEC))
        self.assertEqual(len(api.gateways), 1)
        self.assertEqual(gw["name"], SPEC["name"])


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


class WdsTest(unittest.TestCase):
    def setUp(self):
        self.api = FakeApi()
        self.c = make_client(ONEAPI_ENV, self.api)

    def test_settings_builds_role_arn(self):
        out = ztgw.cmd_wds_settings(self.c)
        self.assertEqual(out["trusted_account_id"], "644370868001")
        self.assertEqual(out["trusted_role_arn"],
                         "arn:aws:iam::644370868001:role/ZscalerTagDiscoveryRole")

    def test_settings_passes_through_arn(self):
        self.api.wds_settings["trustedRoleName"] = "arn:aws:iam::644370868001:role/x/y"
        self.assertEqual(ztgw.cmd_wds_settings(self.c)["trusted_role_arn"],
                         "arn:aws:iam::644370868001:role/x/y")

    def test_settings_missing(self):
        self.api.wds_settings = {}
        with self.assertRaisesRegex(ztgw.ZtgwError, "Workload Discovery enabled"):
            ztgw.cmd_wds_settings(self.c)

    def test_verify_retries_until_iam_propagates(self):
        self.api.permission_failures = 3
        ztgw.cmd_wds_verify(self.c, {"public_cloud_account_id": 77, "role_name": "zs-discovery",
                                     "external_id": "abc-123", "timeout_seconds": 300})
        self.assertEqual(self.api.verified, [("77", {"discoveryRole": "zs-discovery",
                                                     "externalId": "abc-123"})])

    def test_verify_times_out(self):
        self.api.permission_failures = 1000
        with self.assertRaisesRegex(ztgw.ZtgwError, "verification failed after 60s"):
            ztgw.cmd_wds_verify(self.c, {"public_cloud_account_id": 77, "role_name": "r",
                                         "external_id": "e", "timeout_seconds": 60})

    def test_verify_denied_on_http_200_is_not_success(self):
        self.api.permission_failures = 1000
        with self.assertRaisesRegex(ztgw.ZtgwError, "assumeRole=Denied"):
            ztgw.cmd_wds_verify(self.c, {"public_cloud_account_id": 77, "role_name": "r",
                                         "external_id": "e", "timeout_seconds": 30})
        self.assertEqual(self.api.verified, [])

    def test_permission_denials(self):
        self.assertEqual(ztgw._permission_denials({"status": {"assumeRole": "Allowed"}}), [])
        self.assertEqual(ztgw._permission_denials(
            {"status": {"assumeRole": "Allowed", "ec2:DescribeVpcs": "Denied"}}),
            ["ec2:DescribeVpcs=Denied"])
        self.assertEqual(ztgw._permission_denials({"status": {"x": "Allowed"}}),
                         ["assumeRole=missing"])
        self.assertTrue(ztgw._permission_denials({"status": "OK"}))
        self.assertTrue(ztgw._permission_denials(None))

    def test_verify_rejects_bad_input(self):
        for spec in ({"public_cloud_account_id": "x", "role_name": "r", "external_id": "e"},
                     {"public_cloud_account_id": 1, "role_name": "bad role!", "external_id": "e"},
                     {"public_cloud_account_id": 1, "role_name": "r", "external_id": "a b"}):
            with self.subTest(spec=spec), self.assertRaises(ztgw.ZtgwError):
                ztgw.cmd_wds_verify(self.c, spec)

    def test_group_add_and_remove(self):
        ztgw._group_change(self.c, {"group_id": 500, "public_cloud_account_id": 77}, add=True)
        self.assertEqual([m["id"] for m in self.api.groups[500]["publicCloudAccounts"]], [1, 77])
        self.assertEqual(self.api.groups[500]["name"], "consumers")
        self.assertEqual(self.api.activations, 1)
        ztgw._group_change(self.c, {"group_id": 500, "public_cloud_account_id": 77}, add=True)
        self.assertEqual(self.api.activations, 1)  # idempotent: no second PUT/activation
        ztgw._group_change(self.c, {"group_id": 500, "public_cloud_account_id": 77}, add=False)
        self.assertEqual([m["id"] for m in self.api.groups[500]["publicCloudAccounts"]], [1])
        self.assertEqual(self.api.activations, 2)

    def test_group_remove_missing_group_is_ok(self):
        ztgw._group_change(self.c, {"group_id": 999, "public_cloud_account_id": 77}, add=False)

    def test_group_add_missing_group_fails(self):
        with self.assertRaisesRegex(ztgw.ZtgwError, "not found"):
            ztgw._group_change(self.c, {"group_id": 999, "public_cloud_account_id": 77}, add=True)


ACCOUNT_SPEC = {"name": "aws-111122223333", "aws_account_id": "111122223333",
                "role_name": "ZscalerTagDiscoveryRole", "regions": ["us-west-2"]}


class AccountTest(unittest.TestCase):
    def setUp(self):
        self.api = FakeApi()
        self.c = make_client(ONEAPI_ENV, self.api)

    def test_register_generates_external_id(self):
        acct = ztgw.cmd_account_register(self.c, dict(ACCOUNT_SPEC))
        stored = self.api.accounts[acct["id"]]
        self.assertEqual(stored["externalId"], "gen-111122223333")
        self.assertEqual(stored["accountDetails"],
                         {"awsAccountId": "111122223333", "awsRoleName": "ZscalerTagDiscoveryRole",
                          "externalId": "gen-111122223333"})
        self.assertEqual([r["id"] for r in stored["supportedRegions"]], [11])

    def test_register_with_supplied_external_id(self):
        acct = ztgw.cmd_account_register(self.c, {**ACCOUNT_SPEC, "external_id": "shared-1"})
        self.assertEqual(self.api.accounts[acct["id"]]["externalId"], "shared-1")
        self.assertNotIn("/ztw/api/v1/publicCloudInfo/generateExternalId", self.api.paths())

    def test_register_is_idempotent(self):
        first = ztgw.cmd_account_register(self.c, dict(ACCOUNT_SPEC))
        second = ztgw.cmd_account_register(self.c, dict(ACCOUNT_SPEC))
        self.assertEqual(first["id"], second["id"])
        self.assertEqual(len(self.api.accounts), 1)

    def test_register_conflicting_external_id(self):
        ztgw.cmd_account_register(self.c, {**ACCOUNT_SPEC, "external_id": "a"})
        with self.assertRaisesRegex(ztgw.ZtgwError, "different external ID"):
            ztgw.cmd_account_register(self.c, {**ACCOUNT_SPEC, "external_id": "b"})

    def test_register_recovers_from_slow_create(self):
        # The POST creates the account but never confirms (5xx on every retry).
        self.api.account_create_times_out = True
        acct = ztgw.cmd_account_register(self.c, dict(ACCOUNT_SPEC))
        self.assertEqual(acct["accountDetails"]["awsAccountId"], "111122223333")
        self.assertGreaterEqual(len(self.api.accounts), 1)

    def test_register_unsupported_region(self):
        with self.assertRaisesRegex(ztgw.ZtgwError, "not supported for discovery"):
            ztgw.cmd_account_register(self.c, {**ACCOUNT_SPEC, "regions": ["eu-west-9"]})

    def test_register_rejects_bad_spec(self):
        for bad in ({"aws_account_id": "123"}, {"role_name": "a b"}, {"external_id": "x y"},
                    {"regions": []}, {"name": ""}):
            with self.subTest(bad=bad), self.assertRaises(ztgw.ZtgwError):
                ztgw.cmd_account_register(self.c, {**ACCOUNT_SPEC, **bad})

    def test_read_and_delete(self):
        self.assertEqual(ztgw.cmd_account_read(self.c, {"aws_account_id": "111122223333"})["exists"],
                         "false")
        acct = ztgw.cmd_account_register(self.c, dict(ACCOUNT_SPEC))
        out = ztgw.cmd_account_read(self.c, {"aws_account_id": "111122223333"})
        self.assertEqual(out, {"exists": "true", "id": str(acct["id"]),
                               "external_id": "gen-111122223333", "name": "aws-111122223333"})
        ztgw.cmd_account_delete(self.c, {"aws_account_id": "111122223333"})
        self.assertEqual(self.api.accounts, {})
        self.assertEqual(self.api.activations, 1)
        ztgw.cmd_account_delete(self.c, {"aws_account_id": "111122223333"})  # idempotent
        self.assertEqual(self.api.account_deletes, 1)

    def test_duplicate_registrations_fail(self):
        for i in (1, 2):
            self.api.accounts[i] = {"id": i, "accountDetails": {"awsAccountId": "111122223333"}}
        with self.assertRaisesRegex(ztgw.ZtgwError, "duplicates"):
            ztgw.cmd_account_read(self.c, {"aws_account_id": "111122223333"})


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

    def test_wds_settings_cli(self):
        rc, out, err = self.run_main(["ztgw.py", "wds-settings"], LEGACY_ENV, stdin="{}")
        self.assertEqual(rc, 0, err)
        self.assertTrue(json.loads(out)["trusted_role_arn"].startswith("arn:aws:iam::"))

    def test_group_add_cli(self):
        api = FakeApi()
        env = {**ONEAPI_ENV, "ZTGW_GROUP": json.dumps({"group_id": 500,
                                                      "public_cloud_account_id": 9})}
        rc, _, err = self.run_main(["ztgw.py", "group-add"], env, api=api)
        self.assertEqual(rc, 0, err)
        self.assertIn({"id": 9}, api.groups[500]["publicCloudAccounts"])

    def test_account_register_and_read_cli(self):
        api = FakeApi()
        env = {**ONEAPI_ENV, "ZTGW_ACCOUNT": json.dumps(ACCOUNT_SPEC)}
        rc, _, err = self.run_main(["ztgw.py", "account-register"], env, api=api)
        self.assertEqual(rc, 0, err)
        rc, out, err = self.run_main(["ztgw.py", "account-read"], ONEAPI_ENV, api=api,
                                     stdin=json.dumps({"aws_account_id": "111122223333"}))
        self.assertEqual(rc, 0, err)
        self.assertEqual(json.loads(out)["external_id"], "gen-111122223333")

    def test_account_register_cli_bad_spec_fails_before_auth(self):
        api = FakeApi()
        env = {**ONEAPI_ENV, "ZTGW_ACCOUNT": json.dumps({**ACCOUNT_SPEC, "aws_account_id": "1"})}
        rc, _, err = self.run_main(["ztgw.py", "account-register"], env, api=api)
        self.assertEqual(rc, 1)
        self.assertEqual(api.calls, [])

    def test_wds_verify_cli_missing_spec(self):
        rc, _, err = self.run_main(["ztgw.py", "wds-verify"], ONEAPI_ENV)
        self.assertEqual(rc, 1)
        self.assertIn("ZTGW_WDS is not set", err)

    def test_regions(self):
        rc, out, _ = self.run_main(["ztgw.py", "regions"], LEGACY_ENV)
        self.assertEqual(rc, 0)
        self.assertEqual(out.strip(), "us-west-2")


if __name__ == "__main__":
    unittest.main()
