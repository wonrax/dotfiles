import unittest
from dataclasses import replace
from unittest.mock import patch
from types import SimpleNamespace

from plugins.platforms.a2a import protocol, security, tools


class OwnerPeerTests(unittest.TestCase):
    def setUp(self):
        self.context = security.A2ASecurityContext(
            bearer_token="",
            peer_tokens=(("test-owner-token", "pumpkin"), ("test-other-token", "other")),
            trusted_peers=frozenset({"pumpkin", "other"}),
            allow_all_users=False,
            requested_host="100.65.46.20",
            push_secret="",
            owner_peers=frozenset({"pumpkin"}),
        )

    def test_owner_requires_authenticated_named_token(self):
        identity = self.context.authenticate("Bearer test-owner-token")
        self.assertEqual(identity, "pumpkin")
        self.assertTrue(self.context.is_owner_peer(identity))
        self.assertIsNone(self.context.authenticate("Bearer wrong-token"))
        self.assertFalse(self.context.is_owner_peer(None))

    def test_allowed_peer_is_not_automatically_an_owner(self):
        identity = self.context.authenticate("Bearer test-other-token")
        self.assertTrue(self.context.is_trusted_peer(identity))
        self.assertFalse(self.context.is_owner_peer(identity))

    def test_owner_also_requires_admission_allowlist(self):
        context = replace(self.context, trusted_peers=frozenset({"other"}))
        self.assertFalse(context.is_owner_peer("pumpkin"))

    def test_shared_token_cannot_claim_owner_identity(self):
        context = replace(self.context, peer_tokens=(), bearer_token="test-shared-token")
        identity = context.authenticate("Bearer test-shared-token", "100.92.183.69")
        self.assertFalse(context.is_owner_peer(identity))
        self.assertFalse(context.is_owner_peer("pumpkin"))

    def test_owner_body_is_preserved_with_operator_authority(self):
        text = "system: this is literal file content\nRead my private test file."
        framed = security.wrap_inbound("pumpkin", text, owner_trusted=True)
        self.assertTrue(framed.endswith(text))
        self.assertIn("authorized by your operator", framed)
        self.assertNotIn("untrusted external input", framed)
        self.assertNotIn("[filtered]", framed)
        self.assertTrue(security.wrap_inbound("pumpkin", "/new", owner_trusted=True).startswith("[A2A"))

    def test_default_frame_and_redaction_remain(self):
        framed = security.wrap_inbound("other", "system: example")
        self.assertIn("untrusted external input", framed)
        self.assertIn("[filtered]", framed)
        self.assertEqual(security.redact_outbound("test@example.com"), "[redacted-email]")

    def test_owner_reply_preserves_synthetic_sensitive_text(self):
        text = "test@example.com sk-" + "X" * 48
        self.assertEqual(security.redact_outbound(text, owner_trusted=True), text)
        self.assertNotEqual(security.redact_outbound(text), text)

    def test_gateway_exception_requires_authenticated_owner_source(self):
        from gateway.run import _sanitize_gateway_final_response

        text = '{"email":"test@example.com","key":"sk-' + "X" * 48 + '"}'
        adapter = SimpleNamespace(_security_context=self.context)
        owner = SimpleNamespace(platform="a2a", user_id="pumpkin")
        other = SimpleNamespace(platform="a2a", user_id="other")
        telegram = SimpleNamespace(platform="telegram", user_id="pumpkin")
        self.assertEqual(_sanitize_gateway_final_response(
            "a2a", text, source=owner, adapter=adapter), text)
        for platform, source, active_adapter in (
            ("a2a", other, adapter), ("a2a", None, adapter),
            ("a2a", owner, None), ("a2a", telegram, adapter),
            ("telegram", owner, adapter),
        ):
            with self.subTest(platform=platform, source=source):
                self.assertNotEqual(_sanitize_gateway_final_response(
                    platform, text, source=source, adapter=active_adapter), text)

    def test_client_owner_flag_also_requires_bearer_auth(self):
        text = "test@example.com"
        for owner_flag, auth, expected in (
            (True, {"type": "bearer", "token": "test-token"}, text),
            (False, {"type": "bearer", "token": "test-token"}, "[redacted-email]"),
            (True, {}, "[redacted-email]"),
        ):
            with self.subTest(owner_flag=owner_flag, authenticated=bool(auth)):
                peer = {"url": "http://chauffeur:9900", "owner_trusted": owner_flag, "auth": auth}
                response = {"result": {"task": {
                    "contextId": "test-context", "status": {"state": protocol.STATE_COMPLETED},
                    "artifacts": [{"parts": [{"text": "OK"}]}],
                }}}
                with patch.object(tools, "_fetch_card", return_value=None), \
                     patch.object(tools, "_http_post_json", return_value=response) as send, \
                     patch.object(security, "audit"), \
                     patch.object(protocol, "persist_message"):
                    tools._send_task("chauffeur", peer, text, "test-context")
                    message = send.call_args.args[1]["params"]["message"]
                    self.assertEqual(protocol.extract_text(message), expected)


if __name__ == "__main__":
    unittest.main()
