from __future__ import annotations

import hashlib
import http.server
import json
import os
import platform
import shutil
import subprocess
import sys
import threading
from collections.abc import Mapping
from contextlib import contextmanager
from pathlib import Path
from typing import Any
from urllib.parse import urlsplit

import pytest

ACT_IMAGE = "catthehacker/ubuntu:act-latest"
ACT_PATH = "/github/workspace/tests/e2e/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
ACT_CONTAINER_ARCH = os.environ.get(
    "ACT_CONTAINER_ARCH",
    "linux/arm64" if platform.machine() in {"arm64", "aarch64"} else "linux/amd64",
)
CHECKOUT_ACTION_SHA = "11bd71901bbe5b1630ceea73d27597364c9af683"
HEAD_SHA = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
HEAD_BRANCH = "submission"
REPOSITORY = "pythonhk/github-native-event-starter-repo-only"
REPOSITORY_ID = 123456789
PR_NUMBER = 17
PR_ID = 1700000000


def _canonical(value: Any) -> bytes:
    return (
        json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(",", ":"))
        + "\n"
    ).encode("utf-8")


def _read_json(path: Path) -> Any:
    return json.loads(path.read_text(encoding="utf-8"))


def _write_json(path: Path, value: Any) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(_canonical(value))


def _digest(value: Any) -> str:
    return hashlib.sha256(_canonical(value).rstrip(b"\n")).hexdigest()


def _run_git(checkout: Path, *arguments: str) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        ["git", *arguments],
        cwd=checkout,
        text=True,
        capture_output=True,
        check=True,
    )


def _tracked_snapshot(checkout: Path) -> str:
    return _run_git(checkout, "ls-files", "--stage").stdout


def _event(
    *,
    author_id: int,
    base_sha: str,
    head_sha: str = HEAD_SHA,
    head_branch: str = HEAD_BRANCH,
) -> dict[str, Any]:
    return {
        "action": "opened",
        "repository": {
            "id": REPOSITORY_ID,
            "full_name": REPOSITORY,
            "name": "github-native-event-starter-repo-only",
            "owner": {"login": "pythonhk"},
        },
        "pull_request": {
            "number": PR_NUMBER,
            "id": PR_ID,
            "user": {"id": author_id, "login": "participant"},
            "base": {
                "ref": "main",
                "sha": base_sha,
                "repo": {"id": REPOSITORY_ID, "owner": {"login": "pythonhk"}},
            },
            "head": {
                "ref": head_branch,
                "sha": head_sha,
                "repo": {
                    "id": 987654321,
                    "owner": {"login": "participant"},
                    "full_name": "participant/event",
                },
            },
        },
    }


def _dispatch_event(*, ref: str, inputs: Mapping[str, str]) -> dict[str, Any]:
    return {
        "ref": ref,
        "inputs": dict(inputs),
        "repository": {
            "id": REPOSITORY_ID,
            "full_name": REPOSITORY,
            "name": "github-native-event-starter-repo-only",
            "owner": {"login": "pythonhk"},
        },
        "sender": {"login": "organizer"},
    }


def _push_event(*, ref: str, commit_sha: str) -> dict[str, Any]:
    event = _dispatch_event(ref=ref, inputs={})
    event.update({"after": commit_sha, "before": "0" * 40})
    return event


def _prepare_api(
    checkout: Path,
    *,
    event: Mapping[str, Any],
    changed_paths: list[str],
    blobs: Mapping[tuple[str, str], bytes],
) -> Path:
    root = checkout / ".act-e2e"
    _write_json(root / "event.json", event)
    pr_number = event["pull_request"]["number"]
    _write_json(
        root / "pulls" / f"{pr_number}.json",
        [{"filename": path} for path in changed_paths],
    )

    content_map: dict[str, str] = {}
    for index, ((ref, path), content) in enumerate(blobs.items()):
        relative_path = Path("blobs") / str(index)
        target = root / relative_path
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_bytes(content)
        content_map[f"{ref}:{path}"] = relative_path.as_posix()
    _write_json(root / "contents.json", content_map)
    return root / "event.json"


def _checkout(repo_root: Path, destination: Path) -> Path:
    base_sha = _run_git(repo_root, "rev-parse", "HEAD").stdout.strip()
    subprocess.run(
        ["git", "clone", "--local", str(repo_root), str(destination)],
        text=True,
        capture_output=True,
        check=True,
    )
    _run_git(destination, "checkout", "--detach", base_sha)
    _run_git(
        destination,
        "remote",
        "set-url",
        "origin",
        f"https://github.com/{REPOSITORY}.git",
    )
    # The black-box support executable is deliberately copied from the working
    # tree so the test works before the test-only files are committed.
    support_source = repo_root / "tests" / "e2e"
    shutil.copytree(support_source, destination / "tests" / "e2e", dirs_exist_ok=True)
    shutil.copytree(
        repo_root / ".github" / "workflows",
        destination / ".github" / "workflows",
        dirs_exist_ok=True,
    )
    return destination


def _act(
    checkout: Path,
    event_path: Path,
    workflow: str,
    server_url: str,
    action_path: Path,
    event_name: str = "pull_request_target",
) -> subprocess.CompletedProcess[str]:
    artifact_path = checkout / ".act-e2e" / "artifacts"
    command = [
        os.environ.get("ACT_BIN", "act"),
        "--artifact-server-addr=127.0.0.1",
        "--artifact-server-port=0",
        f"--artifact-server-path={artifact_path}",
        "--no-cache-server",
        f"--container-architecture={ACT_CONTAINER_ARCH}",
        "--platform",
        f"ubuntu-24.04={ACT_IMAGE}",
        "--local-repository",
        f"{server_url}/actions/checkout@{CHECKOUT_ACTION_SHA}={action_path}",
        "--directory",
        str(checkout),
        "--container-daemon-socket=-",
        "--container-options",
        (
            "--add-host=host.docker.internal:host-gateway "
            f"-v {checkout / 'tests/e2e/bin/gh'}:/usr/local/bin/gh:ro "
            f"-v {checkout / '.act-e2e'}:/tmp/gh-mock:ro"
        ),
        "--eventpath",
        str(event_path),
        "--workflows",
        workflow,
        "--env",
        "GH_MOCK_ROOT=/tmp/gh-mock",
        "--env",
        f"GITHUB_SERVER_URL={server_url}",
        "--env",
        f"PATH={ACT_PATH}",
        "--secret",
        "GITHUB_TOKEN=act-e2e-token",
        "--rm",
        event_name,
    ]
    return subprocess.run(
        command,
        cwd=checkout,
        text=True,
        capture_output=True,
        check=False,
        timeout=180,
    )


@contextmanager
def _git_server(checkout: Path, tmp_path: Path):
    """Serve the exact test checkout to actions/checkout over local HTTP."""
    fixture_root = checkout / ".act-e2e"
    (fixture_root / "pulls").mkdir(parents=True, exist_ok=True)
    (fixture_root / "blobs").mkdir(parents=True, exist_ok=True)
    if not (fixture_root / "contents.json").exists():
        _write_json(fixture_root / "contents.json", {})
    remote_root = tmp_path / "git-root"
    remote = remote_root / "pythonhk" / "github-native-event-starter-repo-only"
    remote.parent.mkdir(parents=True)
    subprocess.run(
        ["git", "init", "--bare", str(remote)], check=True, capture_output=True
    )
    action_cache = Path.home() / ".cache" / "act" / "actions-checkout.git"
    if not action_cache.is_dir():
        raise AssertionError(f"act action cache is missing: {action_cache}")
    action_source = tmp_path / "actions-checkout"
    subprocess.run(
        ["git", "clone", "--local", str(action_cache), str(action_source)],
        check=True,
        capture_output=True,
    )
    subprocess.run(
        ["git", "checkout", "--detach", CHECKOUT_ACTION_SHA],
        cwd=action_source,
        check=True,
        capture_output=True,
    )
    _run_git(checkout, "config", "user.name", "act-e2e")
    _run_git(checkout, "config", "user.email", "act-e2e@example.invalid")
    _run_git(
        checkout,
        "add",
        "tests/e2e",
        ".github/workflows",
        "registry",
        ".act-e2e/pulls",
        ".act-e2e/blobs",
        ".act-e2e/contents.json",
    )
    _run_git(checkout, "commit", "-m", "act e2e fixture")
    base_sha = _run_git(checkout, "rev-parse", "HEAD").stdout.strip()
    for branch in ("main", "registry"):
        subprocess.run(
            [
                "git",
                "-C",
                str(remote),
                "fetch",
                str(checkout),
                f"{base_sha}:refs/heads/{branch}",
            ],
            check=True,
            capture_output=True,
        )

    server_port = 0

    class GitHttpHandler(http.server.BaseHTTPRequestHandler):
        def _serve_git(self) -> None:
            parsed = urlsplit(self.path)
            length = int(self.headers.get("Content-Length", "0"))
            request_body = self.rfile.read(length)
            environment = os.environ.copy()
            environment.update(
                {
                    "GIT_PROJECT_ROOT": str(remote_root),
                    "GIT_HTTP_EXPORT_ALL": "1",
                    "PATH_INFO": parsed.path,
                    "QUERY_STRING": parsed.query,
                    "REQUEST_METHOD": self.command,
                    "CONTENT_TYPE": self.headers.get("Content-Type", ""),
                    "CONTENT_LENGTH": str(length),
                    "REMOTE_ADDR": self.client_address[0],
                    "SERVER_NAME": "host.docker.internal",
                    "SERVER_PORT": str(server_port),
                    "SERVER_PROTOCOL": self.request_version,
                }
            )
            result = subprocess.run(
                ["git", "http-backend"],
                input=request_body,
                capture_output=True,
                check=False,
                env=environment,
            )
            if result.returncode != 0:
                self.send_error(500, result.stderr.decode("utf-8", "replace"))
                return
            headers, body = result.stdout.split(b"\r\n\r\n", 1)
            status = 200
            response_headers: list[tuple[str, str]] = []
            for line in headers.split(b"\r\n"):
                name, separator, value = line.partition(b": ")
                if not separator:
                    continue
                if name.lower() == b"status":
                    status = int(value.split(b" ", 1)[0])
                    continue
                response_headers.append(
                    (name.decode("ascii"), value.decode("latin-1", "replace"))
                )
            self.send_response(status)
            for name, value in response_headers:
                self.send_header(name, value)
            self.end_headers()
            self.wfile.write(body)

        def do_GET(self) -> None:
            self._serve_git()

        def do_POST(self) -> None:
            self._serve_git()

        def log_message(self, format: str, *args: object) -> None:
            del format, args

    server = http.server.ThreadingHTTPServer(("0.0.0.0", 0), GitHttpHandler)
    server_port = int(server.server_port)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    try:
        yield (
            f"http://host.docker.internal:{server_port}",
            base_sha,
            action_source,
        )
    finally:
        server.shutdown()
        server.server_close()
        thread.join(timeout=5)


def _assert_no_git_mutation(checkout: Path, before: str) -> None:
    assert _tracked_snapshot(checkout) == before
    diff = subprocess.run(
        ["git", "diff", "--exit-code", "--", "."],
        cwd=checkout,
        text=True,
        capture_output=True,
        check=False,
    )
    assert diff.returncode == 0, diff.stdout + diff.stderr


def _require_act() -> None:
    if shutil.which(os.environ.get("ACT_BIN", "act")) is None:
        pytest.fail("act is required for the workflow black-box suite")
    docker_check = subprocess.run(
        ["docker", "info"], text=True, capture_output=True, check=False
    )
    if docker_check.returncode != 0:
        pytest.fail("Docker is required for the workflow black-box suite")
    action_cache = Path.home() / ".cache" / "act" / "actions-checkout.git"
    if not action_cache.is_dir():
        pytest.fail(f"act checkout action is not cached: {action_cache}")


@pytest.fixture
def act_checkout(repo_root: Path, tmp_path: Path) -> Path:
    _require_act()
    return _checkout(repo_root, tmp_path / "checkout")


@pytest.fixture
def source_sha(repo_root: Path) -> str:
    return _run_git(repo_root, "rev-parse", "HEAD").stdout.strip()


def test_team_proposal_workflow_is_the_system_under_test(
    act_checkout: Path,
    repo_root: Path,
    source_sha: str,
) -> None:
    team = _read_json(repo_root / "tests/fixtures/team.json")
    signatures = _read_json(repo_root / "tests/fixtures/signatures.json")
    signatures["proposal_sha256"] = _digest(team)
    proposal_digest = _digest(team["eventctl_proposal"])
    for signature in signatures["signatures"]:
        signature["consent"]["proposal_digest"] = proposal_digest

    proposal_path = f"requests/teams/{team['registration_id']}/team.json"
    signatures_path = f"requests/teams/{team['registration_id']}/signatures.json"
    event = _event(author_id=101, base_sha=source_sha)
    event_path = _prepare_api(
        act_checkout,
        event=event,
        changed_paths=[proposal_path, signatures_path],
        blobs={
            (HEAD_SHA, proposal_path): _canonical(team),
            (HEAD_SHA, signatures_path): _canonical(signatures),
        },
    )
    with _git_server(act_checkout, act_checkout.parent) as (
        server_url,
        base_sha,
        action_path,
    ):
        event["pull_request"]["base"]["sha"] = base_sha
        _write_json(event_path, event)
        before = _tracked_snapshot(act_checkout)
        result = _act(
            act_checkout,
            event_path,
            ".github/workflows/team-proposal.yml",
            server_url,
            action_path,
        )

    assert result.returncode == 0, (
        f"act failed:\nstdout:\n{result.stdout}\nstderr:\n{result.stderr}"
    )
    assert "PENDING_KEY_PROOFS" in result.stdout
    _assert_no_git_mutation(act_checkout, before)


def test_team_proposal_workflow_reaches_ready_after_all_consents(
    act_checkout: Path,
    repo_root: Path,
    source_sha: str,
) -> None:
    team = _read_json(repo_root / "tests/fixtures/team.json")
    signatures = _read_json(repo_root / "tests/fixtures/signatures.json")
    proposal_digest = _digest(team["eventctl_proposal"])
    signatures["proposal_sha256"] = _digest(team)
    for signature in signatures["signatures"]:
        signature["consent"]["proposal_digest"] = proposal_digest
    key_id = "c" * 64
    signatures["signatures"].append(
        {
            "github_id": "103",
            "key_id": key_id,
            "consent": {
                "kind": "team_consent",
                "event_id": "demo-event-2026",
                "actor_id": "103",
                "base_repository": {"id": str(REPOSITORY_ID)},
                "team_id": team["team_id"],
                "key_id": key_id,
                "proposal_digest": proposal_digest,
                "signature": {"key_id": key_id},
            },
        }
    )
    proposal_path = f"requests/teams/{team['registration_id']}/team.json"
    signatures_path = f"requests/teams/{team['registration_id']}/signatures.json"
    event = _event(author_id=101, base_sha=source_sha)
    event_path = _prepare_api(
        act_checkout,
        event=event,
        changed_paths=[proposal_path, signatures_path],
        blobs={
            (HEAD_SHA, proposal_path): _canonical(team),
            (HEAD_SHA, signatures_path): _canonical(signatures),
        },
    )
    with _git_server(act_checkout, act_checkout.parent) as (
        server_url,
        base_sha,
        action_path,
    ):
        event["pull_request"]["base"]["sha"] = base_sha
        _write_json(event_path, event)
        before = _tracked_snapshot(act_checkout)
        result = _act(
            act_checkout,
            event_path,
            ".github/workflows/team-proposal.yml",
            server_url,
            action_path,
        )

    assert result.returncode == 0, (
        f"act failed:\nstdout:\n{result.stdout}\nstderr:\n{result.stderr}"
    )
    assert "READY_TO_ACTIVATE" in result.stdout
    _assert_no_git_mutation(act_checkout, before)


def test_team_proof_workflow_rejects_authenticated_actor_mismatch(
    act_checkout: Path,
    repo_root: Path,
    source_sha: str,
) -> None:
    team = _read_json(repo_root / "tests/fixtures/team.json")
    proof = _read_json(repo_root / "tests/fixtures/proofs/101.json")
    proof["consent"]["proposal_digest"] = _digest(team["eventctl_proposal"])
    proof_path = f"requests/teams/{team['registration_id']}/proofs/102.json"
    event = _event(author_id=102, base_sha=source_sha)
    event_path = _prepare_api(
        act_checkout,
        event=event,
        changed_paths=[proof_path],
        blobs={
            (
                source_sha,
                f"requests/teams/{team['registration_id']}/team.json",
            ): _canonical(team),
            (HEAD_SHA, proof_path): _canonical(proof),
        },
    )
    with _git_server(act_checkout, act_checkout.parent) as (
        server_url,
        base_sha,
        action_path,
    ):
        event["pull_request"]["base"]["sha"] = base_sha
        _write_json(event_path, event)
        before = _tracked_snapshot(act_checkout)
        result = _act(
            act_checkout,
            event_path,
            ".github/workflows/team-proof.yml",
            server_url,
            action_path,
        )

    assert result.returncode != 0
    combined_output = f"{result.stdout}\n{result.stderr}"
    assert "proof actor mismatch" in combined_output, combined_output
    _assert_no_git_mutation(act_checkout, before)


def test_team_proof_workflow_accepts_actor_bound_proof(
    act_checkout: Path,
    repo_root: Path,
    source_sha: str,
) -> None:
    team = _read_json(repo_root / "tests/fixtures/team.json")
    proof = _read_json(repo_root / "tests/fixtures/proofs/101.json")
    proof["consent"]["proposal_digest"] = _digest(team["eventctl_proposal"])
    proof_path = f"requests/teams/{team['registration_id']}/proofs/101.json"
    event = _event(author_id=101, base_sha=source_sha)
    event_path = _prepare_api(
        act_checkout,
        event=event,
        changed_paths=[proof_path],
        blobs={
            (
                source_sha,
                f"requests/teams/{team['registration_id']}/team.json",
            ): _canonical(team),
            (HEAD_SHA, proof_path): _canonical(proof),
        },
    )
    with _git_server(act_checkout, act_checkout.parent) as (
        server_url,
        base_sha,
        action_path,
    ):
        event["pull_request"]["base"]["sha"] = base_sha
        _write_json(event_path, event)
        before = _tracked_snapshot(act_checkout)
        result = _act(
            act_checkout,
            event_path,
            ".github/workflows/team-proof.yml",
            server_url,
            action_path,
        )

    assert result.returncode == 0, (
        f"act failed:\nstdout:\n{result.stdout}\nstderr:\n{result.stderr}"
    )
    assert "key proof structurally valid and actor-bound" in result.stdout
    _assert_no_git_mutation(act_checkout, before)


def test_registration_workflow_accepts_actor_bound_request(
    act_checkout: Path,
    repo_root: Path,
    source_sha: str,
) -> None:
    proof = _read_json(repo_root / "tests/fixtures/proofs/101.json")
    registration = proof["registration"]
    registration.update(
        {
            "key_epoch": "1",
            "participant_key": {
                "key_id": registration["key_id"],
                "public_key": "PUB101",
            },
        }
    )
    request_path = "requests/users/101.json"
    event = _event(author_id=101, base_sha=source_sha)
    event_path = _prepare_api(
        act_checkout,
        event=event,
        changed_paths=[request_path],
        blobs={(HEAD_SHA, request_path): _canonical(registration)},
    )
    with _git_server(act_checkout, act_checkout.parent) as (
        server_url,
        base_sha,
        action_path,
    ):
        event["pull_request"]["base"]["sha"] = base_sha
        _write_json(event_path, event)
        before = _tracked_snapshot(act_checkout)
        result = _act(
            act_checkout,
            event_path,
            ".github/workflows/registration.yml",
            server_url,
            action_path,
        )

    assert result.returncode == 0, (
        f"act failed:\nstdout:\n{result.stdout}\nstderr:\n{result.stderr}"
    )
    assert "registration request structurally valid and actor-bound" in result.stdout
    _assert_no_git_mutation(act_checkout, before)


def test_submission_workflow_accepts_arranged_bundle_without_mutating_registry(
    act_checkout: Path,
    repo_root: Path,
    source_sha: str,
) -> None:
    """The producer runs before act; the submission workflow only validates its output."""
    submission = _read_json(repo_root / "tests/fixtures/submission.json")
    bundle_path_on_host = act_checkout.parent / "producer-output.bin"
    subprocess.run(
        [
            sys.executable,
            "-c",
            "from pathlib import Path; Path(__import__('sys').argv[1]).write_bytes(b'encrypted producer output\\n')",
            str(bundle_path_on_host),
        ],
        check=True,
    )
    bundle = bundle_path_on_host.read_bytes()
    bundle_digest = hashlib.sha256(bundle).hexdigest()
    submission["head_sha"] = HEAD_SHA
    submission["pr_id"] = str(PR_ID)
    submission["head_branch"] = HEAD_BRANCH
    submission["bundle_sha256"] = bundle_digest
    submission["eventctl_request"]["pull_request"]["head_sha"] = HEAD_SHA
    submission["eventctl_request"]["pull_request"]["id"] = str(PR_ID)
    submission["eventctl_request"]["pull_request"]["head_ref"] = HEAD_BRANCH
    submission["eventctl_request"]["bundle"]["sha256"] = bundle_digest

    attempt_dir = f"requests/submissions/{submission['attempt_id']}"
    request_path = f"{attempt_dir}/request.json"
    bundle_path = f"{attempt_dir}/bundle.eventctl"
    event = _event(author_id=101, base_sha=source_sha)
    event_path = _prepare_api(
        act_checkout,
        event=event,
        changed_paths=[request_path, bundle_path],
        blobs={
            (HEAD_SHA, request_path): _canonical(submission),
            (HEAD_SHA, bundle_path): bundle,
            ("registry", "registry/state.json"): (
                repo_root / "tests/fixtures/registry-active.json"
            ).read_bytes(),
        },
    )
    with _git_server(act_checkout, act_checkout.parent) as (
        server_url,
        base_sha,
        action_path,
    ):
        event["pull_request"]["base"]["sha"] = base_sha
        _write_json(event_path, event)
        before = _tracked_snapshot(act_checkout)
        result = _act(
            act_checkout,
            event_path,
            ".github/workflows/submission.yml",
            server_url,
            action_path,
        )

    assert result.returncode == 0, (
        f"act failed:\nstdout:\n{result.stdout}\nstderr:\n{result.stderr}"
    )
    assert "submission request structurally valid" in result.stdout
    _assert_no_git_mutation(act_checkout, before)


def test_registry_workflow_validates_registry_branch(
    act_checkout: Path,
) -> None:
    event = _push_event(ref="refs/heads/registry", commit_sha="0" * 40)
    event_path = act_checkout / ".act-e2e" / "event.json"
    _write_json(event_path, event)
    with _git_server(act_checkout, act_checkout.parent) as (
        server_url,
        base_sha,
        action_path,
    ):
        event["after"] = base_sha
        _write_json(event_path, event)
        before = _tracked_snapshot(act_checkout)
        result = _act(
            act_checkout,
            event_path,
            ".github/workflows/registry.yml",
            server_url,
            action_path,
            event_name="push",
        )

    assert result.returncode == 0, (
        f"act failed:\nstdout:\n{result.stdout}\nstderr:\n{result.stderr}"
    )
    assert "registry / canonical-state" in result.stdout
    _assert_no_git_mutation(act_checkout, before)


def test_scoring_workflow_validates_arranged_result(
    act_checkout: Path,
    repo_root: Path,
) -> None:
    attempt_id = "33333333-3333-4333-8333-333333333333"
    team_id = "22222222-2222-4222-8222-222222222222"
    request_digest = "d" * 64
    state = _read_json(repo_root / "tests/fixtures/registry-active.json")
    state["attempts"][attempt_id] = {
        "attempt_id": attempt_id,
        "team_id": team_id,
        "github_id": "101",
        "request_digest": request_digest,
        "status": "reserved",
    }
    _write_json(act_checkout / "registry" / "state.json", state)
    _write_json(
        act_checkout / "registry" / "users" / "index.json",
        {"schema": "pythonhk.registry-users/v2", "users": state["users"]},
    )
    _write_json(
        act_checkout / "registry" / "teams" / "index.json",
        {"schema": "pythonhk.registry-teams/v2", "teams": state["teams"]},
    )
    _write_json(
        act_checkout / "registry" / "memberships" / "index.json",
        {
            "schema": "pythonhk.registry-memberships/v2",
            "memberships": state["memberships"],
        },
    )
    _write_json(
        act_checkout / "registry" / "submissions" / "index.json",
        {
            "schema": "pythonhk.registry-submissions/v2",
            "attempts": state["attempts"],
        },
    )
    payload_path = act_checkout / "registry" / "scoring" / "act.payload.json"
    _write_json(payload_path, {"grader": "isolated-test", "score": 42})
    payload_digest = hashlib.sha256(payload_path.read_bytes()).hexdigest()
    result_path = act_checkout / "registry" / "scoring" / "act.result.json"
    _write_json(
        result_path,
        {
            "schema": "pythonhk.scoring-result/v2",
            "event_id": state["event_id"],
            "attempt_id": attempt_id,
            "team_id": team_id,
            "status": "accepted",
            "payload_sha256": payload_digest,
            "scorer_id": "isolated-test",
            "scorer_version": "1.0.0",
            "source_attempt_digest": request_digest,
            "issued_at": "2026-08-06T00:00:00Z",
        },
    )
    inputs = {
        "attempt_id": attempt_id,
        "result_path": "registry/scoring/act.result.json",
        "payload_path": "registry/scoring/act.payload.json",
    }
    event = _dispatch_event(ref="refs/heads/registry", inputs=inputs)
    event_path = act_checkout / ".act-e2e" / "event.json"
    _write_json(event_path, event)
    with _git_server(act_checkout, act_checkout.parent) as (
        server_url,
        _base_sha,
        action_path,
    ):
        before = _tracked_snapshot(act_checkout)
        result = _act(
            act_checkout,
            event_path,
            ".github/workflows/scoring.yml",
            server_url,
            action_path,
            event_name="workflow_dispatch",
        )

    assert result.returncode == 0, (
        f"act failed:\nstdout:\n{result.stdout}\nstderr:\n{result.stderr}"
    )
    assert "scoring / isolated-result-check" in result.stdout
    _assert_no_git_mutation(act_checkout, before)


def test_organizer_plan_workflow_does_not_write_registry(
    act_checkout: Path,
) -> None:
    event = _dispatch_event(
        ref="refs/heads/main",
        inputs={
            "operation": "reserve-submission",
            "request_path": "requests/example.json",
        },
    )
    event_path = act_checkout / ".act-e2e" / "event.json"
    _write_json(event_path, event)
    with _git_server(act_checkout, act_checkout.parent) as (
        server_url,
        _base_sha,
        action_path,
    ):
        before = _tracked_snapshot(act_checkout)
        result = _act(
            act_checkout,
            event_path,
            ".github/workflows/admin-plan.yml",
            server_url,
            action_path,
            event_name="workflow_dispatch",
        )

    assert result.returncode == 0, (
        f"act failed:\nstdout:\n{result.stdout}\nstderr:\n{result.stderr}"
    )
    assert "No registry write was performed." in result.stdout
    _assert_no_git_mutation(act_checkout, before)
