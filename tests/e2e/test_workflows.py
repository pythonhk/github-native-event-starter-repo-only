from __future__ import annotations

import hashlib
import http.server
import json
import os
import platform
import shutil
import subprocess
import tarfile
import threading
from collections.abc import Mapping
from contextlib import contextmanager
from dataclasses import dataclass
from datetime import datetime, timedelta, timezone
from pathlib import Path
from typing import Any
from urllib.parse import urlsplit
from urllib.request import urlopen

import pytest


ACT_IMAGE = "catthehacker/ubuntu:act-latest"
ACT_PATH = "/github/workspace/tests/e2e/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
ACT_CONTAINER_ARCH = os.environ.get(
    "ACT_CONTAINER_ARCH",
    "linux/arm64" if platform.machine() in {"arm64", "aarch64"} else "linux/amd64",
)
CHECKOUT_ACTION_SHA = "11bd71901bbe5b1630ceea73d27597364c9af683"
HEAD_SHA = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
REPOSITORY = "pythonhk/github-native-event-starter-repo-only"
REPOSITORY_ID = 123456789
PR_NUMBER = 17
PR_ID = 1700000000


@dataclass(frozen=True)
class Eventctl:
    native: Path
    linux: Path

    def run(self, *arguments: str) -> dict[str, Any]:
        result = subprocess.run(
            [str(self.native), *arguments],
            text=True,
            capture_output=True,
            check=False,
        )
        assert result.returncode == 0, result.stdout + result.stderr
        response = json.loads(result.stdout)
        assert response["ok"] is True, response
        return response["result"]


@dataclass(frozen=True)
class Participant:
    actor_id: str
    signing_private: Path
    recipient_public: Path
    registration: Path
    source_time: str
    record: dict[str, Any]


@dataclass(frozen=True)
class Scenario:
    binding: dict[str, Any]
    formation_registry: dict[str, Any]
    submission_registry: dict[str, Any]
    participants: dict[str, Participant]
    proposal: Path
    consents: dict[str, Path]
    submission: Path
    bundle: Path
    team_id: str
    attempt_id: str


def _canonical(value: object) -> bytes:
    return (
        json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(",", ":"))
        + "\n"
    ).encode()


def _read_json(path: Path) -> dict[str, Any]:
    value = json.loads(path.read_text())
    assert isinstance(value, dict)
    return value


def _write_json(path: Path, value: object) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(_canonical(value))


def _timestamp(value: datetime) -> str:
    return value.astimezone(timezone.utc).replace(microsecond=0).isoformat().replace(
        "+00:00", "Z"
    )


def _run_git(checkout: Path, *arguments: str) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        ["git", *arguments],
        cwd=checkout,
        text=True,
        capture_output=True,
        check=True,
    )


def _workspace_state(checkout: Path) -> tuple[str, str, str]:
    return (
        _run_git(checkout, "ls-files", "--stage").stdout,
        _run_git(checkout, "status", "--short").stdout,
        subprocess.run(
            ["git", "diff", "--", "."],
            cwd=checkout,
            text=True,
            capture_output=True,
            check=True,
        ).stdout,
    )


def _assert_no_git_mutation(
    checkout: Path, before: tuple[str, str, str]
) -> None:
    assert _workspace_state(checkout) == before


def _required_binary(name: str) -> Path:
    configured = os.environ.get(name)
    if not configured:
        pytest.fail(f"{name} is required for the eventctl v2 act E2E suite")
    path = Path(configured)
    if not path.is_file() or not os.access(path, os.X_OK):
        pytest.fail(f"{name} is not an executable file: {path}")
    return path


def _configured_eventctl() -> Eventctl | None:
    native = os.environ.get("EVENTCTL_E2E_NATIVE_BIN")
    linux = os.environ.get("EVENTCTL_E2E_BIN")
    if not native and not linux:
        return None
    return Eventctl(
        native=_required_binary("EVENTCTL_E2E_NATIVE_BIN"),
        linux=_required_binary("EVENTCTL_E2E_BIN"),
    )


def _asset_key(system: str, machine: str) -> str:
    systems = {"Darwin": "darwin", "Linux": "linux"}
    machines = {
        "x86_64": "amd64",
        "AMD64": "amd64",
        "amd64": "amd64",
        "arm64": "arm64",
        "aarch64": "arm64",
    }
    return f"{systems[system]}-{machines[machine]}"


def _download_eventctl(repo_root: Path, destination: Path, asset_key: str) -> Path:
    lock = _read_json(repo_root / "tools" / "eventctl.lock.json")
    version = lock["version"]
    if version == "UNRELEASED":
        pytest.fail(
            "eventctl is not pinned; set both EVENTCTL_E2E_NATIVE_BIN and EVENTCTL_E2E_BIN"
        )
    asset = lock["assets"][asset_key]
    archive = destination / asset["name"]
    binary = destination / "eventctl"
    destination.mkdir()
    with urlopen(
        f"https://github.com/{lock['repository']}/releases/download/v{version}/{asset['name']}",
        timeout=60,
    ) as response:
        archive.write_bytes(response.read())
    assert hashlib.sha256(archive.read_bytes()).hexdigest() == asset["archive_sha256"]
    with tarfile.open(archive, "r:gz") as contents:
        member = contents.getmember("eventctl")
        assert member.isfile()
        source = contents.extractfile(member)
        assert source is not None
        binary.write_bytes(source.read())
    binary.chmod(binary.stat().st_mode | 0o111)
    assert hashlib.sha256(binary.read_bytes()).hexdigest() == asset["binary_sha256"]
    return binary


@pytest.fixture(scope="session")
def eventctl(repo_root: Path, tmp_path_factory: pytest.TempPathFactory) -> Eventctl:
    configured = _configured_eventctl()
    if configured:
        return configured
    root = tmp_path_factory.mktemp("eventctl")
    native_key = _asset_key(platform.system(), platform.machine())
    _, _, linux_machine = ACT_CONTAINER_ARCH.partition("/")
    linux_key = _asset_key("Linux", linux_machine)
    binaries = {
        key: _download_eventctl(repo_root, root / key, key)
        for key in {native_key, linux_key}
    }
    return Eventctl(native=binaries[native_key], linux=binaries[linux_key])


def _event(*, author_id: int, created_at: str) -> dict[str, Any]:
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
            "created_at": created_at,
            "user": {"id": author_id, "login": "participant"},
            "base": {
                "ref": "main",
                "sha": "",
                "repo": {"id": REPOSITORY_ID, "owner": {"login": "pythonhk"}},
            },
            "head": {
                "ref": "participant-request",
                "sha": HEAD_SHA,
                "repo": {
                    "id": 987654321,
                    "owner": {"login": "participant"},
                    "full_name": "participant/event",
                },
            },
        },
    }


def _dispatch_event(*, operation: str, request_path: str, source_times: dict[str, Any]) -> dict[str, Any]:
    return {
        "ref": "refs/heads/main",
        "inputs": {
            "operation": operation,
            "request_path": request_path,
            "source_times": json.dumps(source_times, separators=(",", ":")),
        },
        "repository": {
            "id": REPOSITORY_ID,
            "full_name": REPOSITORY,
            "name": "github-native-event-starter-repo-only",
            "owner": {"login": "pythonhk"},
        },
        "sender": {"login": "organizer"},
    }


def _push_event() -> dict[str, Any]:
    return {
        "ref": "refs/heads/registry",
        "before": "0" * 40,
        "after": "",
        "repository": {
            "id": REPOSITORY_ID,
            "full_name": REPOSITORY,
            "name": "github-native-event-starter-repo-only",
            "owner": {"login": "pythonhk"},
        },
    }


def _prepare_api(
    checkout: Path,
    *,
    event: Mapping[str, Any],
    changed_paths: list[str],
    blobs: Mapping[tuple[str, str], bytes],
) -> Path:
    root = checkout / ".act-e2e"
    _write_json(root / "event.json", dict(event))
    pull_request = event.get("pull_request")
    if isinstance(pull_request, Mapping):
        _write_json(
            root / "pulls" / f"{pull_request['number']}.json",
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
    for relative_path in (
        Path(".github/actions"),
        Path(".github/workflows"),
        Path("event"),
        Path("registry"),
        Path("tests/e2e"),
        Path("tools"),
    ):
        source = repo_root / relative_path
        if source.exists():
            shutil.copytree(source, destination / relative_path, dirs_exist_ok=True)
    return destination


def _act(
    checkout: Path,
    event_path: Path,
    workflow: str,
    server_url: str,
    action_path: Path,
    linux_eventctl: Path,
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
            f"-v {checkout / '.act-e2e'}:/tmp/gh-mock:ro "
            f"-v {linux_eventctl}:/tmp/eventctl:ro"
        ),
        "--eventpath",
        str(event_path),
        "--workflows",
        workflow,
        "--env",
        "GH_MOCK_ROOT=/tmp/gh-mock",
        "--env",
        "EVENTCTL_E2E_BIN=/tmp/eventctl",
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
    fixture_root = checkout / ".act-e2e"
    (fixture_root / "pulls").mkdir(parents=True, exist_ok=True)
    (fixture_root / "blobs").mkdir(parents=True, exist_ok=True)
    if not (fixture_root / "contents.json").exists():
        _write_json(fixture_root / "contents.json", {})
    remote_root = tmp_path / "git-root"
    remote = remote_root / "pythonhk" / "github-native-event-starter-repo-only"
    remote.parent.mkdir(parents=True)
    subprocess.run(["git", "init", "--bare", str(remote)], check=True, capture_output=True)

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
    paths = [
        ".github/actions",
        ".github/workflows",
        "event",
        "registry",
        "tests/e2e",
        "tools",
        ".act-e2e/pulls",
        ".act-e2e/blobs",
        ".act-e2e/contents.json",
    ]
    if (checkout / "requests").exists():
        paths.append("requests")
    _run_git(checkout, "add", *paths)
    _run_git(checkout, "commit", "-m", "act e2e fixture")
    base_sha = _run_git(checkout, "rev-parse", "HEAD").stdout.strip()
    subprocess.run(
        ["git", "-C", str(remote), "fetch", str(checkout), base_sha],
        check=True,
        capture_output=True,
    )
    for branch in ("main", "registry"):
        subprocess.run(
            ["git", "-C", str(remote), "update-ref", f"refs/heads/{branch}", base_sha],
            check=True,
            capture_output=True,
        )
    subprocess.run(
        ["git", "-C", str(remote), "symbolic-ref", "HEAD", "refs/heads/main"],
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
        yield f"http://host.docker.internal:{server_port}", base_sha, action_source
    finally:
        server.shutdown()
        server.server_close()
        thread.join(timeout=5)


def _require_act() -> None:
    if shutil.which(os.environ.get("ACT_BIN", "act")) is None:
        pytest.fail("act is required for the workflow black-box suite")
    docker_check = subprocess.run(["docker", "info"], text=True, capture_output=True, check=False)
    if docker_check.returncode != 0:
        pytest.fail("Docker is required for the workflow black-box suite")
    action_cache = Path.home() / ".cache" / "act" / "actions-checkout.git"
    if not action_cache.is_dir():
        pytest.fail(f"act checkout action is not cached: {action_cache}")


@pytest.fixture
def act_checkout(repo_root: Path, tmp_path: Path) -> Path:
    _require_act()
    return _checkout(repo_root, tmp_path / "checkout")


def _participant(
    eventctl: Eventctl,
    root: Path,
    binding: Path,
    passphrase: Path,
    actor_id: str,
) -> Participant:
    key_directory = root / "keys" / actor_id
    generated = eventctl.run(
        "key-gen",
        "--out",
        str(key_directory),
        "--passphrase-file",
        str(passphrase),
    )
    registration = root / "requests" / "users" / f"{actor_id}.json"
    registration.parent.mkdir(parents=True, exist_ok=True)
    eventctl.run(
        "identity",
        "register",
        "--event",
        str(binding),
        "--actor-id",
        actor_id,
        "--sig-private-key",
        generated["signing_private_key"],
        "--recipient-public-key",
        generated["recipient_public_key"],
        "--passphrase-file",
        str(passphrase),
        "--output",
        str(registration),
    )
    document = _read_json(registration)
    record_path = root / "records" / f"{actor_id}.json"
    record_path.parent.mkdir(parents=True, exist_ok=True)
    eventctl.run(
        "identity",
        "verify",
        "--event",
        str(binding),
        "--input",
        str(registration),
        "--expect-actor-id",
        actor_id,
        "--source-time",
        document["issued_at"],
        "--output",
        str(record_path),
    )
    return Participant(
        actor_id=actor_id,
        signing_private=Path(generated["signing_private_key"]),
        recipient_public=Path(generated["recipient_public_key"]),
        registration=registration,
        source_time=document["issued_at"],
        record=_read_json(record_path),
    )


@pytest.fixture
def scenario(eventctl: Eventctl, tmp_path: Path) -> Scenario:
    root = tmp_path / "scenario"
    passphrase = root / "passphrase.txt"
    passphrase.parent.mkdir(parents=True)
    passphrase.write_text("test passphrase\n")
    now = datetime.now(timezone.utc).replace(microsecond=0)
    binding = {
        "v": 2,
        "kind": "event-binding",
        "protocol": "eventctl/v2",
        "event_id": "act-event-2026",
        "event_epoch": 1,
        "repository_id": str(REPOSITORY_ID),
        "valid_from": _timestamp(now - timedelta(minutes=1)),
        "valid_until": _timestamp(now + timedelta(days=8)),
        "terms_sha256": "a" * 64,
        "ttl_seconds": {"registration": 604800, "team": 604800, "submission": 86400},
        "limits": {"team_min": 1, "team_max": 5, "attempts_per_team": 10, "attempts_total": 200},
    }
    binding_path = root / "event" / "binding.json"
    _write_json(binding_path, binding)
    reference = eventctl.run("doctor", "--event", str(binding_path))["event"]
    participants = {
        actor_id: _participant(eventctl, root, binding_path, passphrase, actor_id)
        for actor_id in ("101", "102")
    }
    formation_registry = {
        "v": 2,
        "kind": "event-registry",
        "event": reference,
        "revision": 2,
        "phase": "formation_open",
        "enabled": True,
        "disabled_reason": "",
        "identities": [participants[actor_id].record for actor_id in ("101", "102")],
        "teams": [],
        "attempts": [],
    }
    formation_registry_path = root / "registry" / "formation.json"
    _write_json(formation_registry_path, formation_registry)
    proposal = root / "requests" / "teams" / "22222222-2222-4222-8222-222222222222" / "proposal.json"
    proposal.parent.mkdir(parents=True, exist_ok=True)
    eventctl.run(
        "team",
        "propose",
        "--event",
        str(binding_path),
        "--registry",
        str(formation_registry_path),
        "--team-id",
        "22222222-2222-4222-8222-222222222222",
        "--actor-id",
        "101",
        "--member",
        "101",
        "--member",
        "102",
        "--sig-private-key",
        str(participants["101"].signing_private),
        "--passphrase-file",
        str(passphrase),
        "--output",
        str(proposal),
    )
    consents: dict[str, Path] = {}
    for actor_id, participant in participants.items():
        consent = proposal.parent / "proofs" / f"{actor_id}.json"
        consent.parent.mkdir(parents=True, exist_ok=True)
        eventctl.run(
            "team",
            "consent",
            "--event",
            str(binding_path),
            "--registry",
            str(formation_registry_path),
            "--proposal",
            str(proposal),
            "--actor-id",
            actor_id,
            "--sig-private-key",
            str(participant.signing_private),
            "--passphrase-file",
            str(passphrase),
            "--output",
            str(consent),
        )
        consents[actor_id] = consent
    verification = root / "records" / "team.json"
    team_arguments = [
        "team",
        "verify",
        "--event",
        str(binding_path),
        "--registry",
        str(formation_registry_path),
        "--proposal",
        str(proposal),
        "--proposal-source-time",
        _read_json(proposal)["issued_at"],
    ]
    for actor_id, consent in consents.items():
        team_arguments.extend(
            [
                "--consent",
                str(consent),
                "--consent-source-time",
                f"{actor_id}={_read_json(consent)['issued_at']}",
            ]
        )
    team_arguments.extend(["--output", str(verification)])
    eventctl.run(*team_arguments)
    verified_team = _read_json(verification)
    submission_registry = {
        **formation_registry,
        "revision": 3,
        "phase": "submissions_open",
        "teams": [
            {
                "team_id": verified_team["team_id"],
                "proposal_sha256": verified_team["proposal_sha256"],
                "members": verified_team["members"],
            }
        ],
    }
    payload = root / "bundle"
    payload.write_bytes(b"opaque package payload\n")
    submission = root / "requests" / "submissions" / "33333333-3333-4333-8333-333333333333" / "request.json"
    submission.parent.mkdir(parents=True, exist_ok=True)
    eventctl.run(
        "submission",
        "prepare",
        "--event",
        str(binding_path),
        "--input",
        str(payload),
        "--team-id",
        verified_team["team_id"],
        "--attempt-id",
        "33333333-3333-4333-8333-333333333333",
        "--actor-id",
        "101",
        "--sig-private-key",
        str(participants["101"].signing_private),
        "--passphrase-file",
        str(passphrase),
        "--output",
        str(submission),
    )
    return Scenario(
        binding=binding,
        formation_registry=formation_registry,
        submission_registry=submission_registry,
        participants=participants,
        proposal=proposal,
        consents=consents,
        submission=submission,
        bundle=payload,
        team_id=verified_team["team_id"],
        attempt_id="33333333-3333-4333-8333-333333333333",
    )


def _configure_checkout(checkout: Path, scenario: Scenario, registry: dict[str, Any]) -> None:
    _write_json(checkout / "event" / "binding.json", scenario.binding)
    _write_json(checkout / "registry" / "state.json", registry)


def _exercise(
    checkout: Path,
    event: dict[str, Any],
    event_path: Path,
    workflow: str,
    eventctl: Eventctl,
    event_name: str = "pull_request_target",
) -> subprocess.CompletedProcess[str]:
    with _git_server(checkout, checkout.parent) as (server_url, base_sha, action_path):
        if "pull_request" in event:
            event["pull_request"]["base"]["sha"] = base_sha
        elif event_name == "push":
            event["after"] = base_sha
        _write_json(event_path, event)
        before = _workspace_state(checkout)
        result = _act(
            checkout,
            event_path,
            workflow,
            server_url,
            action_path,
            eventctl.linux,
            event_name,
        )
    _assert_no_git_mutation(checkout, before)
    return result


def test_registration_workflow_verifies_a_real_eventctl_request(
    act_checkout: Path, eventctl: Eventctl, scenario: Scenario
) -> None:
    _configure_checkout(act_checkout, scenario, scenario.formation_registry)
    participant = scenario.participants["101"]
    path = "requests/users/101.json"
    event = _event(author_id=101, created_at=participant.source_time)
    event_path = _prepare_api(
        act_checkout,
        event=event,
        changed_paths=[path],
        blobs={(HEAD_SHA, path): participant.registration.read_bytes()},
    )
    result = _exercise(
        act_checkout,
        event,
        event_path,
        ".github/workflows/registration.yml",
        eventctl,
    )
    assert result.returncode == 0, result.stdout + result.stderr
    assert "registration request is signed" in result.stdout


def test_registration_workflow_rejects_a_transferred_identity(
    act_checkout: Path, eventctl: Eventctl, scenario: Scenario
) -> None:
    _configure_checkout(act_checkout, scenario, scenario.formation_registry)
    path = "requests/users/102.json"
    event = _event(author_id=102, created_at=scenario.participants["101"].source_time)
    event_path = _prepare_api(
        act_checkout,
        event=event,
        changed_paths=[path],
        blobs={(HEAD_SHA, path): scenario.participants["101"].registration.read_bytes()},
    )
    result = _exercise(
        act_checkout,
        event,
        event_path,
        ".github/workflows/registration.yml",
        eventctl,
    )
    assert result.returncode != 0


def test_team_proposal_workflow_keeps_the_request_pending(
    act_checkout: Path, eventctl: Eventctl, scenario: Scenario
) -> None:
    _configure_checkout(act_checkout, scenario, scenario.formation_registry)
    path = f"requests/teams/{scenario.team_id}/proposal.json"
    event = _event(author_id=101, created_at=_read_json(scenario.proposal)["issued_at"])
    event_path = _prepare_api(
        act_checkout,
        event=event,
        changed_paths=[path],
        blobs={(HEAD_SHA, path): scenario.proposal.read_bytes()},
    )
    result = _exercise(
        act_checkout,
        event,
        event_path,
        ".github/workflows/team-proposal.yml",
        eventctl,
    )
    assert result.returncode == 0, result.stdout + result.stderr
    assert "pending member consents" in result.stdout


def test_team_consent_workflow_binds_the_github_actor(
    act_checkout: Path, eventctl: Eventctl, scenario: Scenario
) -> None:
    _configure_checkout(act_checkout, scenario, scenario.formation_registry)
    proposal_path = act_checkout / "requests" / "teams" / scenario.team_id / "proposal.json"
    proposal_path.parent.mkdir(parents=True, exist_ok=True)
    proposal_path.write_bytes(scenario.proposal.read_bytes())
    path = f"requests/teams/{scenario.team_id}/proofs/102.json"
    event = _event(author_id=102, created_at=_read_json(scenario.consents["102"])["issued_at"])
    event_path = _prepare_api(
        act_checkout,
        event=event,
        changed_paths=[path],
        blobs={
            ("main", f"requests/teams/{scenario.team_id}/proposal.json"): scenario.proposal.read_bytes(),
            (HEAD_SHA, path): scenario.consents["102"].read_bytes(),
        },
    )
    result = _exercise(
        act_checkout,
        event,
        event_path,
        ".github/workflows/team-proof.yml",
        eventctl,
    )
    assert result.returncode == 0, result.stdout + result.stderr
    assert "team consent is actor-bound" in result.stdout


def test_team_consent_workflow_rejects_another_members_proof(
    act_checkout: Path, eventctl: Eventctl, scenario: Scenario
) -> None:
    _configure_checkout(act_checkout, scenario, scenario.formation_registry)
    proposal_path = act_checkout / "requests" / "teams" / scenario.team_id / "proposal.json"
    proposal_path.parent.mkdir(parents=True, exist_ok=True)
    proposal_path.write_bytes(scenario.proposal.read_bytes())
    path = f"requests/teams/{scenario.team_id}/proofs/102.json"
    event = _event(author_id=102, created_at=_read_json(scenario.consents["101"])["issued_at"])
    event_path = _prepare_api(
        act_checkout,
        event=event,
        changed_paths=[path],
        blobs={
            ("main", f"requests/teams/{scenario.team_id}/proposal.json"): scenario.proposal.read_bytes(),
            (HEAD_SHA, path): scenario.consents["101"].read_bytes(),
        },
    )
    result = _exercise(
        act_checkout,
        event,
        event_path,
        ".github/workflows/team-proof.yml",
        eventctl,
    )
    assert result.returncode != 0


def test_submission_workflow_verifies_active_membership_and_payload(
    act_checkout: Path, eventctl: Eventctl, scenario: Scenario
) -> None:
    _configure_checkout(act_checkout, scenario, scenario.submission_registry)
    request_path = f"requests/submissions/{scenario.attempt_id}/request.json"
    bundle_path = f"requests/submissions/{scenario.attempt_id}/bundle"
    event = _event(author_id=101, created_at=_read_json(scenario.submission)["issued_at"])
    event_path = _prepare_api(
        act_checkout,
        event=event,
        changed_paths=[request_path, bundle_path],
        blobs={
            (HEAD_SHA, request_path): scenario.submission.read_bytes(),
            (HEAD_SHA, bundle_path): scenario.bundle.read_bytes(),
            ("registry", "registry/state.json"): _canonical(scenario.submission_registry),
        },
    )
    result = _exercise(
        act_checkout,
        event,
        event_path,
        ".github/workflows/submission.yml",
        eventctl,
    )
    assert result.returncode == 0, result.stdout + result.stderr
    assert "submission request is signed" in result.stdout


def test_submission_workflow_rejects_actor_replay(
    act_checkout: Path, eventctl: Eventctl, scenario: Scenario
) -> None:
    _configure_checkout(act_checkout, scenario, scenario.submission_registry)
    request_path = f"requests/submissions/{scenario.attempt_id}/request.json"
    bundle_path = f"requests/submissions/{scenario.attempt_id}/bundle"
    event = _event(author_id=102, created_at=_read_json(scenario.submission)["issued_at"])
    event_path = _prepare_api(
        act_checkout,
        event=event,
        changed_paths=[request_path, bundle_path],
        blobs={
            (HEAD_SHA, request_path): scenario.submission.read_bytes(),
            (HEAD_SHA, bundle_path): scenario.bundle.read_bytes(),
            ("registry", "registry/state.json"): _canonical(scenario.submission_registry),
        },
    )
    result = _exercise(
        act_checkout,
        event,
        event_path,
        ".github/workflows/submission.yml",
        eventctl,
    )
    assert result.returncode != 0


def test_registry_workflow_validates_the_single_authoritative_document(
    act_checkout: Path, eventctl: Eventctl, scenario: Scenario
) -> None:
    _configure_checkout(act_checkout, scenario, scenario.submission_registry)
    event = _push_event()
    event_path = _prepare_api(act_checkout, event=event, changed_paths=[], blobs={})
    result = _exercise(
        act_checkout,
        event,
        event_path,
        ".github/workflows/registry.yml",
        eventctl,
        event_name="push",
    )
    assert result.returncode == 0, result.stdout + result.stderr
    assert "registry / canonical-state" in result.stdout


def test_admin_plan_verifies_the_full_team_without_a_state_write(
    act_checkout: Path, eventctl: Eventctl, scenario: Scenario
) -> None:
    _configure_checkout(act_checkout, scenario, scenario.formation_registry)
    proposal_path = act_checkout / "requests" / "teams" / scenario.team_id / "proposal.json"
    proposal_path.parent.mkdir(parents=True, exist_ok=True)
    proposal_path.write_bytes(scenario.proposal.read_bytes())
    for actor_id, consent in scenario.consents.items():
        target = proposal_path.parent / "proofs" / f"{actor_id}.json"
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_bytes(consent.read_bytes())
    source_times = {
        "proposal": _read_json(scenario.proposal)["issued_at"],
        "consents": {
            actor_id: _read_json(consent)["issued_at"]
            for actor_id, consent in scenario.consents.items()
        },
    }
    event = _dispatch_event(
        operation="activate-team",
        request_path=f"requests/teams/{scenario.team_id}",
        source_times=source_times,
    )
    event_path = _prepare_api(act_checkout, event=event, changed_paths=[], blobs={})
    result = _exercise(
        act_checkout,
        event,
        event_path,
        ".github/workflows/admin-plan.yml",
        eventctl,
        event_name="workflow_dispatch",
    )
    assert result.returncode == 0, result.stdout + result.stderr
    assert '"verified":true' in result.stdout
    assert "No registry write was performed." in result.stdout
