"""Phase 10 — Object Storage: attachments.

Both upload paths are covered: streaming multipart through the API, and the
presigned PUT that sends bytes straight to object storage. The interesting
assertions are the negative ones — a 12 MB file, a ``.html`` renamed ``.png``,
and an upload aimed at somebody else's task.
"""

from __future__ import annotations

import time

import pytest
import requests

from .assertions import (
    UPLOAD_ID_RE,
    assert_attachment_shape,
    assert_error_envelope,
    assert_success_envelope,
)
from .client import ApiClient
from .util import parse_iso

pytestmark = pytest.mark.phase10

MAX_FILE_SIZE = 10 * 1024 * 1024  # FR4.1

PNG_MAGIC = b"\x89PNG\r\n\x1a\n"
PDF_MAGIC = b"%PDF-1.7\n"
GIF_MAGIC = b"GIF89a"


def _png(size: int = 2048) -> bytes:
    return PNG_MAGIC + b"\x00" * max(0, size - len(PNG_MAGIC))


def _pdf(size: int = 2048) -> bytes:
    return PDF_MAGIC + b"%" * max(0, size - len(PDF_MAGIC))


# ---------------------------------------------------------------------------
# Multipart upload
# ---------------------------------------------------------------------------


def test_multipart_upload_returns_an_attachment(user: ApiClient, task: dict) -> None:
    resp = user.upload_attachment(task["id"], "diagram.png", _png(), "image/png")
    data = assert_success_envelope(resp, 201)
    assert set(data) == {"attachment"}, f"upload data must be {{attachment}}, got {sorted(data)}"
    attachment = assert_attachment_shape(resp, data["attachment"])

    assert attachment["taskId"] == task["id"]
    assert attachment["fileName"] == "diagram.png"
    assert attachment["fileSize"] == len(_png())
    assert attachment["mimeType"] == "image/png"
    assert attachment["url"].startswith("http"), (
        f"{user.impl}: attachment.url must be an absolute presigned URL, got "
        f"{attachment['url']!r}"
    )


def test_uploaded_attachment_appears_in_the_list(user: ApiClient, task: dict) -> None:
    uploaded = user.upload_attachment(task["id"], "notes.pdf", _pdf(), "application/pdf")
    attachment = assert_success_envelope(uploaded, 201)["attachment"]

    listed = user.list_attachments(task["id"])
    data = assert_success_envelope(listed, 200)
    assert isinstance(data, list), (
        f"{user.impl}: the attachment list returns `data` as a bare array (unpaginated)"
    )
    ids = {a["id"] for a in data}
    assert attachment["id"] in ids
    for entry in data:
        assert_attachment_shape(listed, entry)


def test_attachment_can_be_deleted(user: ApiClient, task: dict) -> None:
    uploaded = user.upload_attachment(task["id"], "temp.png", _png(), "image/png")
    attachment = assert_success_envelope(uploaded, 201)["attachment"]

    deleted = user.delete_attachment(task["id"], attachment["id"])
    data = assert_success_envelope(deleted, 200)
    assert set(data) == {"message"}

    remaining = user.list_attachments(task["id"])
    ids = {a["id"] for a in assert_success_envelope(remaining, 200)}
    assert attachment["id"] not in ids

    assert_error_envelope(
        user.delete_attachment(task["id"], attachment["id"]), 404, "NOT_FOUND"
    )


@pytest.mark.slow
@pytest.mark.timeout(180)
def test_a_file_over_10mb_is_refused(user: ApiClient, task: dict) -> None:
    oversized = _png(MAX_FILE_SIZE + 1024)
    resp = user.upload_attachment(task["id"], "huge.png", oversized, "image/png")
    resp.implemented()
    assert resp.status in (400, 413), (
        f"{user.impl}: a {len(oversized):,}-byte upload returned {resp.status}; the cap "
        f"is {MAX_FILE_SIZE:,} bytes (FR4.1), so 413 or 400.\n{resp.exchange.render()}"
    )
    assert_error_envelope(resp, resp.status)


def test_a_file_at_the_limit_is_accepted_or_cleanly_refused(user: ApiClient, task: dict) -> None:
    """Boundary: exactly 10 MB is the largest legal file."""
    resp = user.upload_attachment(task["id"], "atlimit.png", _png(MAX_FILE_SIZE), "image/png")
    resp.implemented()
    assert resp.status in (201, 413), (
        f"{user.impl}: a file of exactly {MAX_FILE_SIZE:,} bytes returned {resp.status}"
    )


@pytest.mark.parametrize(
    "filename,content,mime",
    [
        ("payload.exe", b"MZ\x90\x00", "application/x-msdownload"),
        ("script.sh", b"#!/bin/sh\necho hi\n", "application/x-sh"),
        ("page.html", b"<html><body>hi</body></html>", "text/html"),
    ],
    ids=["executable", "shell_script", "html"],
)
def test_disallowed_media_types_are_refused(
    user: ApiClient, task: dict, filename: str, content: bytes, mime: str
) -> None:
    resp = user.upload_attachment(task["id"], filename, content, mime)
    resp.implemented()
    assert resp.status in (400, 415), (
        f"{user.impl}: uploading {mime} returned {resp.status}. The allow-list covers "
        f"images, PDF, plain text, CSV, ZIP and the Office types — everything else is "
        f"refused.\n{resp.exchange.render()}"
    )


def test_content_is_verified_by_magic_bytes_not_by_extension(
    user: ApiClient, task: dict
) -> None:
    """SEC3.4 — an HTML file renamed ``.png`` is still an HTML file.

    The client controls the file name and the declared MIME type. Trusting
    either is how stored XSS gets into an image bucket that some page later
    serves with ``Content-Type: text/html``.
    """
    disguised = b"<html><script>alert(document.cookie)</script></html>"
    resp = user.upload_attachment(task["id"], "innocent.png", disguised, "image/png")
    resp.implemented()
    assert resp.status in (400, 415), (
        f"{user.impl}: an HTML payload declared as image/png and named .png was "
        f"accepted ({resp.status}). The file type must be determined by sniffing the "
        f"leading bytes, not by the extension or the client's Content-Type.\n"
        f"{resp.exchange.render()}"
    )


def test_a_mime_type_that_disagrees_with_the_content_is_refused(
    user: ApiClient, task: dict
) -> None:
    resp = user.upload_attachment(task["id"], "actually.gif", _pdf(), "image/gif")
    resp.implemented()
    assert resp.status in (400, 415), (
        f"{user.impl}: PDF bytes declared as image/gif were accepted ({resp.status})"
    )


def test_an_empty_file_is_refused(user: ApiClient, task: dict) -> None:
    resp = user.upload_attachment(task["id"], "empty.png", b"", "image/png")
    resp.implemented()
    assert resp.status in (400, 415), (
        f"{user.impl}: a zero-byte upload returned {resp.status}; fileSize has "
        f"`minimum: 1`"
    )


@pytest.mark.parametrize(
    "filename",
    ["../../etc/passwd", "dir/nested.png", "back\\slash.png"],
    ids=["traversal", "forward_slash", "backslash"],
)
def test_file_names_with_path_separators_are_refused(
    user: ApiClient, task: dict, filename: str
) -> None:
    """``fileName`` is ``^[^/\\\\]+$`` — a separator is a path-traversal attempt."""
    resp = user.upload_attachment(task["id"], filename, _png(), "image/png")
    resp.implemented()
    if resp.status == 201:
        stored = resp.data["attachment"]["fileName"]
        assert "/" not in stored and "\\" not in stored, (
            f"{user.impl}: stored the file name {stored!r} verbatim. It must be "
            f"rejected or sanitised — the object key is built from it."
        )
    else:
        assert resp.status in (400, 415), f"unexpected status {resp.status}"


# ---------------------------------------------------------------------------
# Ownership
# ---------------------------------------------------------------------------


def test_uploading_to_another_users_task_returns_404(
    user: ApiClient, second_user: ApiClient
) -> None:
    victim_task = second_user.create_task("Not yours").expect(201).task
    resp = user.upload_attachment(victim_task["id"], "sneaky.png", _png(), "image/png")
    resp.implemented()
    assert resp.status != 403, (
        f"{user.impl}: uploading to another user's task returned 403; as everywhere "
        f"else in this API the answer is 404.\n{resp.exchange.render()}"
    )
    assert_error_envelope(resp, 404, "NOT_FOUND")


def test_listing_another_users_attachments_returns_404(
    user: ApiClient, second_user: ApiClient
) -> None:
    victim_task = second_user.create_task("Not yours").expect(201).task
    second_user.upload_attachment(victim_task["id"], "private.png", _png(), "image/png")
    assert_error_envelope(user.list_attachments(victim_task["id"]), 404, "NOT_FOUND")


def test_deleting_another_users_attachment_returns_404(
    user: ApiClient, second_user: ApiClient
) -> None:
    victim_task = second_user.create_task("Not yours").expect(201).task
    uploaded = second_user.upload_attachment(
        victim_task["id"], "private.png", _png(), "image/png"
    )
    uploaded.implemented()
    if uploaded.status != 201:
        pytest.skip("could not seed an attachment to attack")
    attachment_id = uploaded.data["attachment"]["id"]

    resp = user.delete_attachment(victim_task["id"], attachment_id)
    resp.implemented()
    assert resp.status == 404, f"{user.impl}: expected 404, got {resp.status}"

    survivors = second_user.list_attachments(victim_task["id"])
    ids = {a["id"] for a in assert_success_envelope(survivors, 200)}
    assert attachment_id in ids, f"{user.impl}: the cross-user delete actually deleted it"


def test_attachments_on_a_nonexistent_task_return_404(user: ApiClient) -> None:
    assert_error_envelope(user.list_attachments("tsk_doesnotexist00000"), 404, "NOT_FOUND")


# ---------------------------------------------------------------------------
# Presigned upload (FR9)
# ---------------------------------------------------------------------------


def test_presign_returns_a_complete_upload_descriptor(user: ApiClient, task: dict) -> None:
    resp = user.presign_attachment(task["id"], "report.pdf", 4096, "application/pdf")
    data = assert_success_envelope(resp, 201)
    assert set(data) == {"upload"}, f"presign data must be {{upload}}, got {sorted(data)}"
    upload = data["upload"]

    expected = {
        "uploadId", "url", "method", "headers", "objectKey", "expiresIn", "expiresAt",
    }
    assert set(upload) == expected, (
        f"{user.impl}: presign payload key set does not match the contract "
        f"(missing={sorted(expected - set(upload))}, "
        f"unexpected={sorted(set(upload) - expected)})"
    )
    assert UPLOAD_ID_RE.match(upload["uploadId"])
    assert upload["method"] == "PUT"
    assert upload["url"].startswith("http")
    assert isinstance(upload["headers"], dict)
    assert 0 < upload["expiresIn"] <= 3600, (
        f"{user.impl}: expiresIn is {upload['expiresIn']}s; FR9.1 specifies 900 and the "
        f"schema caps it at 3600"
    )
    assert upload["objectKey"].startswith("attachments/"), (
        f"{user.impl}: objectKey should be attachments/{{task_id}}/{{uuid}}/{{filename}} "
        f"(INF3.4), got {upload['objectKey']!r}"
    )
    assert task["id"] in upload["objectKey"]


def test_presigned_object_key_is_unguessable(user: ApiClient, task: dict) -> None:
    """Two presigns for the same file must not collide — the key carries a UUID."""
    first = user.presign_attachment(task["id"], "same.pdf", 1024, "application/pdf")
    second = user.presign_attachment(task["id"], "same.pdf", 1024, "application/pdf")
    first.expect(201)
    second.expect(201)
    assert first.data["upload"]["objectKey"] != second.data["upload"]["objectKey"], (
        f"{user.impl}: two presigns for the same file name produced the same object "
        f"key. A predictable key lets anyone who can guess it read or overwrite the "
        f"object."
    )


@pytest.mark.slow
@pytest.mark.timeout(180)
def test_presigned_put_followed_by_complete_creates_the_row(
    user: ApiClient, task: dict
) -> None:
    """The full FR9 flow — and the point where it usually breaks.

    ``complete`` must verify the object actually landed, with the declared size.
    Trusting the client's word here means a database row pointing at nothing.
    """
    content = _pdf(4096)
    presign = user.presign_attachment(task["id"], "flow.pdf", len(content), "application/pdf")
    upload = assert_success_envelope(presign, 201)["upload"]

    try:
        put = requests.put(
            upload["url"], data=content, headers=upload["headers"], timeout=30
        )
    except requests.RequestException as exc:
        pytest.skip(
            f"{user.impl}: the presigned URL host is not reachable from the test process "
            f"({exc}). Inside docker-compose S3_ENDPOINT is http://seaweedfs:8333, which "
            f"does not resolve here — set S3_ENDPOINT to a host-reachable address."
        )

    assert put.status_code in (200, 201, 204), (
        f"{user.impl}: PUT to the presigned URL returned {put.status_code}: "
        f"{put.text[:400]}\nThe signature or the replayed headers are wrong."
    )

    completed = user.complete_attachment(
        task["id"], upload["uploadId"], "flow.pdf", len(content), "application/pdf"
    )
    attachment = assert_attachment_shape(
        completed, assert_success_envelope(completed, 201)["attachment"]
    )
    assert attachment["fileSize"] == len(content)

    listed = user.list_attachments(task["id"])
    ids = {a["id"] for a in assert_success_envelope(listed, 200)}
    assert attachment["id"] in ids


def test_complete_with_an_unknown_upload_id_is_refused(user: ApiClient, task: dict) -> None:
    resp = user.complete_attachment(
        task["id"], "upl_neverissued000", "ghost.pdf", 1024, "application/pdf"
    )
    resp.implemented()
    assert resp.status in (400, 404), (
        f"{user.impl}: completing an upload that was never presigned returned "
        f"{resp.status}\n{resp.exchange.render()}"
    )


def test_complete_with_a_size_that_does_not_match_is_refused(
    user: ApiClient, task: dict
) -> None:
    """``fileSize`` is verified by a HEAD on the object, not taken on trust."""
    content = _pdf(2048)
    presign = user.presign_attachment(task["id"], "mismatch.pdf", len(content), "application/pdf")
    upload = assert_success_envelope(presign, 201)["upload"]
    try:
        requests.put(upload["url"], data=content, headers=upload["headers"], timeout=30)
    except requests.RequestException as exc:
        pytest.skip(f"{user.impl}: presigned URL not reachable from the test process ({exc})")

    resp = user.complete_attachment(
        task["id"], upload["uploadId"], "mismatch.pdf", len(content) * 4, "application/pdf"
    )
    resp.implemented()
    assert resp.status == 400, (
        f"{user.impl}: completing with a declared size of {len(content) * 4} for a "
        f"{len(content)}-byte object returned {resp.status}. The size must be confirmed "
        f"against the stored object.\n{resp.exchange.render()}"
    )


def test_presign_rejects_an_oversized_declared_size(user: ApiClient, task: dict) -> None:
    resp = user.presign_attachment(
        task["id"], "huge.pdf", MAX_FILE_SIZE + 1, "application/pdf"
    )
    assert_error_envelope(resp, 400, "VALIDATION_ERROR")


def test_presign_for_another_users_task_returns_404(
    user: ApiClient, second_user: ApiClient
) -> None:
    victim_task = second_user.create_task("Not yours").expect(201).task
    resp = user.presign_attachment(victim_task["id"], "x.pdf", 1024, "application/pdf")
    resp.implemented()
    assert resp.status != 403
    assert_error_envelope(resp, 404, "NOT_FOUND")


def test_a_tampered_presigned_url_is_rejected(user: ApiClient, task: dict) -> None:
    """Proves the signature is enforced, without waiting 15 minutes for expiry."""
    presign = user.presign_attachment(task["id"], "tamper.pdf", 2048, "application/pdf")
    upload = assert_success_envelope(presign, 201)["upload"]

    url = upload["url"]
    if "Signature=" not in url and "signature=" not in url.lower():
        pytest.skip(f"{user.impl}: the presigned URL carries no visible signature to tamper with")
    tampered = url.replace("Signature=", "Signature=00").replace("signature=", "signature=00")

    try:
        resp = requests.put(tampered, data=_pdf(2048), headers=upload["headers"], timeout=30)
    except requests.RequestException as exc:
        pytest.skip(f"{user.impl}: presigned URL host not reachable ({exc})")

    assert resp.status_code in (400, 401, 403), (
        f"{user.impl}: a presigned URL with a corrupted signature was accepted "
        f"({resp.status_code}). The bucket is effectively public-write."
    )


def test_expiry_metadata_is_internally_consistent(user: ApiClient, task: dict) -> None:
    presign = user.presign_attachment(task["id"], "clock.pdf", 1024, "application/pdf")
    upload = assert_success_envelope(presign, 201)["upload"]

    expires_at = parse_iso(upload["expiresAt"])
    issued = parse_iso(presign.meta["timestamp"])
    delta = (expires_at - issued).total_seconds()
    assert abs(delta - upload["expiresIn"]) <= 5, (
        f"{user.impl}: expiresAt is {delta:.0f}s after the response timestamp but "
        f"expiresIn says {upload['expiresIn']}s. The two must describe the same instant."
    )


@pytest.mark.slow
@pytest.mark.timeout(300)
def test_a_presigned_url_stops_working_after_it_expires(user: ApiClient, task: dict) -> None:
    """Real expiry, run only when the configured lifetime is short enough to wait for.

    Production uses 900 s (FR9.1) and no test suite should sit for fifteen
    minutes. Set ``S3_PRESIGN_EXPIRY_SECONDS=60`` on the service to exercise this.
    """
    presign = user.presign_attachment(task["id"], "expiring.pdf", 1024, "application/pdf")
    upload = assert_success_envelope(presign, 201)["upload"]
    lifetime = int(upload["expiresIn"])

    if lifetime > 120:
        pytest.skip(
            f"{user.impl}: the presign lifetime is {lifetime}s — too long to wait for in "
            f"a test. Re-run with S3_PRESIGN_EXPIRY_SECONDS=60 to exercise real expiry; "
            f"signature enforcement itself is covered by the tamper test."
        )

    time.sleep(lifetime + 5)
    try:
        resp = requests.put(
            upload["url"], data=_pdf(1024), headers=upload["headers"], timeout=30
        )
    except requests.RequestException as exc:
        pytest.skip(f"{user.impl}: presigned URL host not reachable ({exc})")

    assert resp.status_code in (400, 401, 403), (
        f"{user.impl}: the presigned URL still accepted a PUT {lifetime + 5}s after "
        f"issue, past its {lifetime}s lifetime ({resp.status_code}). A signature that "
        f"never expires is a permanent write credential in the client's history."
    )


def test_attachment_upload_requires_authentication(api: ApiClient) -> None:
    resp = api.post(
        "/tasks/tsk_whatever000/attachments",
        files={"file": ("x.png", _png(), "image/png")},
        auth=False,
    )
    assert_error_envelope(resp, 401, "UNAUTHORIZED")
