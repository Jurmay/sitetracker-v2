# -*- coding: utf-8 -*-
"""Admin people endpoints: invites are all-or-nothing; owner role and lookups are guarded."""
import unittest
from types import SimpleNamespace
from unittest import mock

from fastapi import HTTPException

from app.routers import admin_users as au


def _user(owner=False, project_company="c1"):
    client = mock.MagicMock()
    client.rpc.return_value.execute.return_value.data = owner
    client.table.return_value.select.return_value.eq.return_value.execute.return_value.data = [{"company_id": project_company}]
    return SimpleNamespace(id="admin-1", email="a@x", client=client)


def _request(origin="https://sitetracker-v2-frontend.vercel.app"):
    return SimpleNamespace(headers={"origin": origin})


class InviteTest(unittest.TestCase):
    def setUp(self):
        self.service = mock.MagicMock()
        self.service.auth.admin.invite_user_by_email.return_value = SimpleNamespace(user=SimpleNamespace(id="new-1"))
        patches = [
            mock.patch.object(au, "get_service_db", return_value=self.service),
            mock.patch.object(au, "_require_admin_or_owner"),
            mock.patch.object(au, "_company_profile", return_value=None),
            mock.patch.dict("os.environ", {"ALLOWED_ORIGINS": "https://sitetracker-v2-frontend.vercel.app"}),
        ]
        for p in patches:
            p.start()
            self.addCleanup(p.stop)

    def payload(self, role="cashier"):
        return au.InviteUserPayload(project_id="p1", email="new@x.bt", name="New Person", role=role)

    def test_role_failure_undoes_the_account(self):
        with mock.patch.object(au, "_set_role", side_effect=HTTPException(status_code=403, detail="no")):
            with self.assertRaises(HTTPException):
                au.invite_user(self.payload(), _request(), _user())
        self.service.auth.admin.delete_user.assert_called_once_with("new-1")

    def test_success_sets_role_and_link_back_to_app(self):
        with mock.patch.object(au, "_set_role", return_value={"role": "cashier"}) as set_role:
            out = au.invite_user(self.payload(), _request(), _user())
        self.assertEqual(out["user_id"], "new-1")
        set_role.assert_called_once()
        options = self.service.auth.admin.invite_user_by_email.call_args.args[1]
        self.assertEqual(options["redirect_to"], "https://sitetracker-v2-frontend.vercel.app")
        self.service.auth.admin.delete_user.assert_not_called()

    def test_admin_cannot_invite_an_owner(self):
        with self.assertRaises(HTTPException) as ctx:
            au.invite_user(self.payload(role="company_owner"), _request(), _user(owner=False))
        self.assertEqual(ctx.exception.status_code, 403)
        self.service.auth.admin.invite_user_by_email.assert_not_called()

    def test_unknown_origin_falls_back_to_the_app(self):
        self.assertEqual(au._app_url(_request("https://evil.example")), "https://sitetracker-v2-frontend.vercel.app")


class LookupTest(unittest.TestCase):
    def test_email_wildcards_are_escaped(self):
        user = _user()
        au._company_profile(user, "a_b%c@x.bt")
        pattern = user.client.table.return_value.select.return_value.ilike.call_args.args[1]
        self.assertEqual(pattern, "a\\_b\\%c@x.bt")

    def test_cannot_remove_own_admin_access(self):
        with mock.patch.object(au, "_require_admin_or_owner"), mock.patch.object(au, "_check_role"):
            with self.assertRaises(HTTPException) as ctx:
                au.set_role_status(au.RoleStatusPayload(project_id="p1", user_id="admin-1", role="admin", active=False), _user())
        self.assertEqual(ctx.exception.status_code, 400)


if __name__ == "__main__":
    unittest.main()
