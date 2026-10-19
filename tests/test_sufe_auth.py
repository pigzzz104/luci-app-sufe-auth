#!/usr/bin/env python3
"""Unit tests for the pure 802.1X helpers in root/usr/sbin/sufe_auth."""

import argparse
import hashlib
import importlib.machinery
import importlib.util
import os
import struct
import sys
import unittest
from unittest import mock

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SCRIPT = os.path.join(ROOT, "root", "usr", "sbin", "sufe_auth")

spec = importlib.util.spec_from_loader(
    "sufe_auth",
    importlib.machinery.SourceFileLoader("sufe_auth", SCRIPT),
)
sufe = importlib.util.module_from_spec(spec)
sys.modules["sufe_auth"] = sufe
spec.loader.exec_module(sufe)


class TestFrames(unittest.TestCase):
    def test_build_eapol_header(self):
        src = bytes.fromhex("001122334455")
        dst = bytes.fromhex("66778899aabb")
        frame = sufe.build_eapol(src, dst, sufe.EAPOL_START)
        self.assertEqual(frame[0:6], dst)
        self.assertEqual(frame[6:12], src)
        self.assertEqual(struct.unpack("!H", frame[12:14])[0], sufe.ETHERTYPE_EAPOL)
        self.assertEqual(frame[14], 1)  # EAPOL version
        self.assertEqual(frame[15], sufe.EAPOL_START)
        self.assertEqual(struct.unpack("!H", frame[16:18])[0], 0)

    def test_eap_response_length(self):
        payload = b"user@cmcc"
        eap = sufe.build_eap_response(7, sufe.EAP_TYPE_ID, payload)
        code, eap_id, length, req_type = struct.unpack("!BBHB", eap[:5])
        self.assertEqual(code, sufe.EAP_RESPONSE)
        self.assertEqual(eap_id, 7)
        self.assertEqual(length, 5 + len(payload))
        self.assertEqual(req_type, sufe.EAP_TYPE_ID)
        self.assertEqual(eap[5:], payload)

    def test_parse_identity_request(self):
        src = bytes.fromhex("aabbccddeeff")
        dst = bytes.fromhex("001122334455")
        eap = struct.pack("!BBHB", sufe.EAP_REQUEST, 9, 5 + 4, sufe.EAP_TYPE_ID) + b"test"
        frame = sufe.build_eapol(src, dst, sufe.EAPOL_EAPPACKET, eap)
        parsed = sufe.parse_frame(frame)
        self.assertIsNotNone(parsed)
        self.assertEqual(parsed.src, src)
        self.assertEqual(parsed.eap_code, sufe.EAP_REQUEST)
        self.assertEqual(parsed.eap_id, 9)
        self.assertEqual(parsed.eap_type, sufe.EAP_TYPE_ID)
        self.assertEqual(parsed.eap_data, b"test")

    def test_parse_vlan_tagged_frame(self):
        src = bytes.fromhex("aabbccddeeff")
        dst = bytes.fromhex("001122334455")
        eap = struct.pack("!BBHB", sufe.EAP_REQUEST, 3, 5, sufe.EAP_TYPE_ID)
        plain = sufe.build_eapol(src, dst, sufe.EAPOL_EAPPACKET, eap)
        tagged = plain[:12] + struct.pack("!HH", sufe.ETHERTYPE_VLAN, 2) + plain[12:]
        parsed = sufe.parse_frame(tagged)
        self.assertIsNotNone(parsed)
        self.assertEqual(parsed.src, src)
        self.assertEqual(parsed.eap_type, sufe.EAP_TYPE_ID)

    def test_parse_success(self):
        src = bytes.fromhex("aabbccddeeff")
        dst = bytes.fromhex("001122334455")
        eap = struct.pack("!BBH", sufe.EAP_SUCCESS, 42, 4)
        frame = sufe.build_eapol(src, dst, sufe.EAPOL_EAPPACKET, eap)
        parsed = sufe.parse_frame(frame)
        self.assertIsNotNone(parsed)
        self.assertEqual(parsed.eap_code, sufe.EAP_SUCCESS)
        self.assertEqual(parsed.eap_id, 42)
        self.assertIsNone(parsed.eap_type)

    def test_parse_start(self):
        src = bytes.fromhex("aabbccddeeff")
        frame = sufe.build_eapol(sufe.PAE_GROUP, src, sufe.EAPOL_START)
        parsed = sufe.parse_frame(frame)
        self.assertIsNotNone(parsed)
        self.assertEqual(parsed.eapol_type, sufe.EAPOL_START)
        self.assertIsNone(parsed.eap_code)

    def test_short_frame(self):
        self.assertIsNone(sufe.parse_frame(b"\x00" * 10))


class TestPayloads(unittest.TestCase):
    def test_pap_payload(self):
        payload = sufe.build_pap_payload("secret", "20230001@cmcc")
        self.assertEqual(payload[0], 6)
        self.assertEqual(payload[1:7], b"secret")
        self.assertEqual(payload[7:], b"20230001@cmcc")

    def test_pap_rejects_long_password(self):
        with self.assertRaises(ValueError):
            sufe.build_pap_payload("x" * 256, "user")

    def test_md5_payload(self):
        challenge = bytes(range(16))
        payload = sufe.build_md5_payload(7, "secret", challenge, "user")
        expected = hashlib.md5(bytes([7]) + b"secret" + challenge).digest()
        self.assertEqual(payload[0], 16)
        self.assertEqual(payload[1:17], expected)
        self.assertEqual(payload[17:], b"user")


class TestConfigHelpers(unittest.TestCase):
    def test_parse_mac(self):
        self.assertEqual(sufe.parse_mac("00:11:22:33:44:55").hex(),
                         "001122334455")
        self.assertEqual(sufe.parse_mac("00-11-22-33-44-55").hex(),
                         "001122334455")
        self.assertIsNone(sufe.parse_mac("bad"))
        self.assertIsNone(sufe.parse_mac(""))

    def test_as_bool(self):
        self.assertTrue(sufe.as_bool("1"))
        self.assertTrue(sufe.as_bool("true"))
        self.assertTrue(sufe.as_bool("on"))
        self.assertFalse(sufe.as_bool("0"))
        self.assertFalse(sufe.as_bool(""))
        self.assertTrue(sufe.as_bool("", default=True))

    def test_as_float_clamps(self):
        self.assertEqual(sufe.as_float("12", 5, 10, 20), 12)
        self.assertEqual(sufe.as_float("1", 5, 10, 20), 10)
        self.assertEqual(sufe.as_float("100", 5, 10, 20), 20)
        self.assertEqual(sufe.as_float("bad", 5, 10, 20), 5)

    def test_load_config_from_uci(self):
        args = argparse.Namespace(
            ifname=None, network=None, username=None, password=None,
            mac=None, switch_mac=None,
        )
        values = {
            "ifname": "eth1",
            "network": "wan",
            "username": "20230001@cmcc",
            "password": "secret",
            "mac": "00:11:22:33:44:55",
            "switch_mac": "58:ae:a8:88:0c:31",
            "eapol_version": "2",
            "logoff_on_stop": "0",
            "dhcp_grace": "120",
        }

        def fake_uci(section, option, default=""):
            return values.get(option, default)

        with mock.patch.object(sufe, "uci_get", side_effect=fake_uci):
            cfg = sufe.load_config("wan", args)
        self.assertEqual(cfg.ifname, "eth1")
        self.assertEqual(cfg.network, "wan")
        self.assertEqual(cfg.username, "20230001@cmcc")
        self.assertEqual(cfg.eapol_version, 2)
        self.assertEqual(cfg.dhcp_grace, 120.0)
        self.assertFalse(cfg.logoff_on_stop)
        self.assertEqual(cfg.switch_mac.hex(), "58aea8880c31")
        self.assertEqual(cfg.status_path, "/var/run/sufe_auth.eth1.json")

    def test_load_config_requires_credentials(self):
        args = argparse.Namespace(
            ifname="eth1", network="wan", username=None, password=None,
            mac=None, switch_mac=None,
        )
        with mock.patch.object(sufe, "uci_get", return_value=""):
            with self.assertRaises(ValueError):
                sufe.load_config("wan", args)

    def test_load_config_rejects_bad_interface(self):
        args = argparse.Namespace(
            ifname="eth1;reboot", network="wan", username="u", password="p",
            mac=None, switch_mac=None,
        )
        with self.assertRaises(ValueError):
            sufe.load_config("wan", args)


class TestStateHelpers(unittest.TestCase):
    def _cfg(self, ifname="eth1"):
        return sufe.Config(
            section="wan", ifname=ifname, network="wan",
            username="u", password="p", status_path="/tmp/sufe-test.json",
        )

    def test_vlan_detection(self):
        self.assertTrue(self._cfg("eth0.2").is_vlan)
        self.assertFalse(self._cfg("eth1").is_vlan)

    def test_recovery_backoff_is_bounded(self):
        client = sufe.SufeAuthClient(self._cfg())
        client.recovery_count = 1
        client.schedule_after_recovery()
        first = client.recovery_not_before
        client.recovery_count = 10
        client.schedule_after_recovery()
        second = client.recovery_not_before
        self.assertGreater(second, first)
        self.assertLessEqual(second - sufe.monotonic(), 300.0)

    def test_success_does_not_extend_wait_dhcp_deadline(self):
        client = sufe.SufeAuthClient(self._cfg())
        client.state = sufe.STATE_WAIT_DHCP
        client.dhcp_deadline = 12345.0
        client.on_success(sufe.Frame(src=b"", dst=b"", eapol_type=0,
                                     eap_code=sufe.EAP_SUCCESS, eap_id=1))
        self.assertEqual(client.dhcp_deadline, 12345.0)
        self.assertEqual(client.state, sufe.STATE_WAIT_DHCP)

    def test_refresh_does_not_clear_gateway_failures(self):
        client = sufe.SufeAuthClient(self._cfg())
        client.state = sufe.STATE_ONLINE
        client.gateway_failures = 2
        client.on_success(sufe.Frame(src=b"", dst=b"", eapol_type=0,
                                     eap_code=sufe.EAP_SUCCESS, eap_id=2))
        self.assertEqual(client.gateway_failures, 2)
        self.assertEqual(client.state, sufe.STATE_ONLINE)



class TestRecoverySequence(unittest.TestCase):
    def _client(self, ifname="eth1"):
        cfg = sufe.Config(
            section="wan", ifname=ifname, network="wan",
            username="u", password="p", status_path=f"/tmp/sufe-{ifname}.json",
        )
        return sufe.SufeAuthClient(cfg)

    def test_physical_recovery_does_not_logoff(self):
        client = self._client("eth1")
        with mock.patch.object(sufe, "carrier_up", return_value=True), \
             mock.patch.object(sufe, "ipv4_address", return_value=None), \
             mock.patch.object(client, "send_logoff") as logoff, \
             mock.patch.object(client, "init_socket", return_value=True), \
             mock.patch.object(client, "start_auth") as start, \
             mock.patch.object(sufe, "run_cmd") as run:
            client.start_recovery("test")
            t = client.recovery_step_at
            client.tick_recovery(t + client.cfg.recovery_settle + 1)
            t = client.recovery_step_at
            client.tick_recovery(t + 1)  # step 1: link down
            t = client.recovery_step_at
            client.tick_recovery(t + client.cfg.recovery_link_down + 1)
            t = client.recovery_step_at
            client.tick_recovery(t + 1)  # step 3: carrier up
            t = client.recovery_step_at
            client.tick_recovery(t + 1)  # step 4: re-init + auth
        logoff.assert_not_called()
        start.assert_called_once()
        commands = [call.args[0] for call in run.call_args_list]
        self.assertIn(["ip", "link", "set", "eth1", "down"], commands)
        self.assertIn(["ip", "link", "set", "eth1", "up"], commands)

    def test_vlan_recovery_logs_off_without_link_reset(self):
        client = self._client("eth0.2")
        with mock.patch.object(sufe, "carrier_up", return_value=True), \
             mock.patch.object(sufe, "ipv4_address", return_value=None), \
             mock.patch.object(client, "send_logoff") as logoff, \
             mock.patch.object(client, "init_socket", return_value=True), \
             mock.patch.object(client, "start_auth") as start, \
             mock.patch.object(sufe, "run_cmd") as run:
            client.start_recovery("test")
            t = client.recovery_step_at
            client.tick_recovery(t + client.cfg.recovery_settle + 1)
            t = client.recovery_step_at
            client.tick_recovery(t + 1)
            t = client.recovery_step_at
            client.tick_recovery(t + 1)
        logoff.assert_called_once()
        start.assert_called_once()
        run.assert_not_called()


if __name__ == "__main__":
    unittest.main(verbosity=2)


class TestMacGate(unittest.TestCase):
    def test_waits_for_configured_mac(self):
        cfg = sufe.Config(
            section="wan", ifname="eth1", network="wan",
            username="u", password="p",
            configured_mac="00:11:22:33:44:55",
            status_path="/tmp/sufe-mac.json",
        )
        client = sufe.SufeAuthClient(cfg)
        with mock.patch.object(sufe, "read_mac",
                               return_value=bytes.fromhex("aabbccddeeff")), \
             mock.patch.object(sufe, "monotonic", return_value=100.0):
            self.assertFalse(client.mac_ready())
        with mock.patch.object(sufe, "read_mac",
                               return_value=bytes.fromhex("001122334455")):
            self.assertTrue(client.mac_ready())
            self.assertTrue(client.mac_matches_config())
        with mock.patch.object(sufe, "read_mac",
                               return_value=bytes.fromhex("aabbccddeeff")):
            self.assertFalse(client.mac_matches_config())


class TestStartDestination(unittest.TestCase):
    def _client(self, switch_mac):
        cfg = sufe.Config(
            section="wan", ifname="eth1", network="wan",
            username="u", password="p", status_path="/tmp/sufe-start.json",
            switch_mac=switch_mac,
        )
        return sufe.SufeAuthClient(cfg)

    def test_start_is_single_unicast_to_switch(self):
        client = self._client(bytes.fromhex("58aea8880c31"))
        with mock.patch.object(client, "send_frame") as send:
            client.send_start()
        send.assert_called_once_with(bytes.fromhex("58aea8880c31"), sufe.EAPOL_START)

    def test_start_falls_back_to_multicast_without_switch_mac(self):
        client = self._client(None)
        with mock.patch.object(client, "send_frame") as send:
            client.send_start()
        send.assert_called_once_with(sufe.PAE_GROUP, sufe.EAPOL_START)
