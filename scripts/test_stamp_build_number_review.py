#!/usr/bin/env python
"""Windows-local regression checks for scripts/stamp-build-number.sh review fixes."""
from __future__ import annotations

import os
import re
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts" / "stamp-build-number.sh"
pass_n = 0
fail_n = 0


def report(ok: bool, label: str, detail: str = "") -> None:
    global pass_n, fail_n
    if ok:
        pass_n += 1
        print(f"PASS {label}")
    else:
        fail_n += 1
        print(f"FAIL {label}")
        if detail:
            print(f"  {detail}")


def write_plist(path: Path, value: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(
        '<?xml version="1.0" encoding="UTF-8"?>\n'
        '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" '
        '"http://www.apple.com/DTDs/PropertyList-1.0.dtd">\n'
        f'<plist version="1.0"><dict><key>CFBundleVersion</key>'
        f'<string>{value}</string></dict></plist>\n',
        encoding="utf-8",
    )


def make_buddy(path: Path) -> None:
    # A single-token executable so `PLISTBUDDY=...` remains a valid shell assignment.
    path.write_text(
        "#!/bin/sh\n"
        "exec python - \"$@\" <<'PY'\n"
        "import re, sys\n"
        "from pathlib import Path\n"
        "args = sys.argv[1:]\n"
        "cmd = ''\n"
        "plist = None\n"
        "i = 0\n"
        "while i < len(args):\n"
        "    if args[i] == '-c' and i + 1 < len(args):\n"
        "        cmd = args[i + 1]; i += 2; continue\n"
        "    plist = args[i]; i += 1\n"
        "if not plist:\n"
        "    sys.exit(1)\n"
        "path = Path(plist)\n"
        "text = path.read_text(encoding='utf-8') if path.exists() else ''\n"
        "if cmd.startswith('Print'):\n"
        "    m = re.search(r'<string>(.*?)</string>', text, re.S)\n"
        "    sys.stdout.write(m.group(1) if m else '')\n"
        "elif cmd.startswith('Set') or cmd.startswith('Add'):\n"
        "    value = cmd.split()[-1]\n"
        "    path.write_text(\n"
        "        '<?xml version=\"1.0\" encoding=\"UTF-8\"?>\\n'\n"
        "        '<!DOCTYPE plist PUBLIC \"-//Apple//DTD PLIST 1.0//EN\" '\n"
        "        '\"http://www.apple.com/DTDs/PropertyList-1.0.dtd\">\\n'\n"
        "        f'<plist version=\"1.0\"><dict><key>CFBundleVersion</key>'\n"
        "        f'<string>{value}</string></dict></plist>\\n',\n"
        "        encoding='utf-8',\n"
        "    )\n"
        "else:\n"
        "    sys.exit(1)\n"
        "PY\n",
        encoding="utf-8",
        newline="\n",
    )
    path.chmod(0o755)


def git(repo: Path, *args: str) -> None:
    subprocess.check_call(["git", "-C", str(repo), *args], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)


def init_repo(repo: Path, commits: int) -> None:
    if repo.exists():
        shutil.rmtree(repo)
    repo.mkdir(parents=True)
    git(repo, "init", "-q")
    git(repo, "config", "user.email", "test@example.com")
    git(repo, "config", "user.name", "Test")
    readme = repo / "README"
    for i in range(commits):
        readme.write_text(f"{i}\n", encoding="utf-8")
        git(repo, "add", "README")
        git(repo, "commit", "-qm", f"c{i}")


def patched_script(workdir: Path, buddy: Path, floor: int | None = None, name: str = "stamp.sh") -> Path:
    text = SCRIPT.read_text(encoding="utf-8")
    text = text.replace("/usr/libexec/PlistBuddy", buddy.as_posix())
    if floor is not None:
        text = text.replace("ACCEPTED_BUILD_FLOOR=0", f"ACCEPTED_BUILD_FLOOR={floor}")
    out = workdir / name
    out.write_text(text, encoding="utf-8", newline="\n")
    return out


def run_script(script: Path, env: dict[str, str]) -> tuple[int, str]:
    full = {**os.environ, **env}
    completed = subprocess.run(
        ["sh", str(script)],
        env=full,
        capture_output=True,
        text=True,
    )
    return completed.returncode, (completed.stdout + completed.stderr).strip()


def main() -> int:
    with tempfile.TemporaryDirectory(prefix="stamp-review-") as tmp:
        workdir = Path(tmp)
        buddy = workdir / "plistbuddy.py"
        make_buddy(buddy)
        script = patched_script(workdir, buddy)

        # Standalone print mode.
        code, out = run_script(SCRIPT, {"SRCROOT": str(ROOT)})
        report(code == 0, "standalone print exits 0", out)
        report(bool(re.fullmatch(r"[0-9]+", out)), "standalone print is numeric", out)

        # Multi-commit app with empty signing identity after stamping.
        repo = workdir / "repo"
        init_repo(repo, 5)
        app = workdir / "app"
        write_plist(app / "Info.plist", "2")
        write_plist(app / "PlugIns" / "HermesLiveActivity.appex" / "Info.plist", "2")
        code, out = run_script(
            script,
            {
                "SRCROOT": str(repo),
                "TARGET_BUILD_DIR": str(app),
                "INFOPLIST_PATH": "Info.plist",
                "PRODUCT_NAME": "HermesMobile",
                "WRAPPER_EXTENSION": "app",
                "PLUGINS_FOLDER_PATH": "PlugIns",
                "CODE_SIGNING_ALLOWED": "YES",
                "EXPANDED_CODE_SIGN_IDENTITY": "",
                "TARGET_NAME": "HermesMobile",
            },
        )
        report(code == 1, "empty signing identity fails after stamping", out)
        report("EXPANDED_CODE_SIGN_IDENTITY is empty" in out, "empty identity names the failure", out)

        # Missing PlugIns.
        shutil.rmtree(app / "PlugIns", ignore_errors=True)
        write_plist(app / "Info.plist", "2")
        code, out = run_script(
            script,
            {
                "SRCROOT": str(repo),
                "TARGET_BUILD_DIR": str(app),
                "INFOPLIST_PATH": "Info.plist",
                "PRODUCT_NAME": "HermesMobile",
                "WRAPPER_EXTENSION": "app",
                "PLUGINS_FOLDER_PATH": "PlugIns",
                "CODE_SIGNING_ALLOWED": "NO",
                "TARGET_NAME": "HermesMobile",
            },
        )
        report(code == 1, "missing PlugIns fails for the app target", out)
        report("no embedded extensions found" in out, "missing PlugIns names the failure", out)

        # A one-commit tree is legitimate at ACCEPTED_BUILD_FLOOR=0 and must stamp.
        thin = workdir / "thin"
        init_repo(thin, 1)
        thin_app = workdir / "thin-app"
        write_plist(thin_app / "Info.plist", "0")
        write_plist(thin_app / "PlugIns" / "HermesLiveActivity.appex" / "Info.plist", "0")
        code, out = run_script(
            script,
            {
                "SRCROOT": str(thin),
                "TARGET_BUILD_DIR": str(thin_app),
                "INFOPLIST_PATH": "Info.plist",
                "PRODUCT_NAME": "HermesMobile",
                "WRAPPER_EXTENSION": "app",
                "PLUGINS_FOLDER_PATH": "PlugIns",
                "CODE_SIGNING_ALLOWED": "NO",
                "TARGET_NAME": "HermesMobile",
            },
        )
        report(code == 0, "a one-commit archive stamps at floor 0", out)
        report("-> 1" in out, "the one-commit archive is stamped 1", out)

        # And a tree at or below a raised floor must not reach an archive. The
        # shipped constant stays 0; this copy declares a higher one, which is
        # what raising it after an accepted upload looks like.
        raised = patched_script(workdir, buddy, floor=5, name="stamp-floor5.sh")
        write_plist(thin_app / "Info.plist", "0")
        write_plist(thin_app / "PlugIns" / "HermesLiveActivity.appex" / "Info.plist", "0")
        code, out = run_script(
            raised,
            {
                "SRCROOT": str(thin),
                "TARGET_BUILD_DIR": str(thin_app),
                "INFOPLIST_PATH": "Info.plist",
                "PRODUCT_NAME": "HermesMobile",
                "WRAPPER_EXTENSION": "app",
                "PLUGINS_FOLDER_PATH": "PlugIns",
                "CODE_SIGNING_ALLOWED": "NO",
                "TARGET_NAME": "HermesMobile",
            },
        )
        report(code == 1, "an archive below a raised accepted-build floor fails", out)
        report("accepted-build floor 5" in out, "the raised floor names itself in the failure", out)

        code, out = run_script(
            script,
            {
                "SRCROOT": str(thin),
                "TARGET_BUILD_DIR": str(thin_app),
                "INFOPLIST_PATH": "Info.plist",
                "PRODUCT_NAME": "HermesMobile",
                "WRAPPER_EXTENSION": "app",
                "PLUGINS_FOLDER_PATH": "PlugIns",
                "CODE_SIGNING_ALLOWED": "NO",
                "TARGET_NAME": "HermesAppTests",
            },
        )
        report(code == 0, "test target is exempt from the archive floor", out)

        code, out = run_script(
            script,
            {
                "SRCROOT": str(thin),
                "TARGET_BUILD_DIR": str(thin_app),
                "INFOPLIST_PATH": "Info.plist",
                "PRODUCT_NAME": "HermesMobile",
                "WRAPPER_EXTENSION": "app",
                "PLUGINS_FOLDER_PATH": "PlugIns",
                "CODE_SIGNING_ALLOWED": "NO",
                "TARGET_NAME": "HermesMobile",
                "ENABLE_PREVIEWS": "YES",
            },
        )
        report(code == 0, "preview mode is exempt from the archive floor", out)

        code, out = run_script(script, {"SRCROOT": str(thin)})
        report(code == 0, "print mode still works on a one-commit tree", out)
        report(out == "1", "print mode reports the raw one-commit count", out)

    print()
    print(f"stamp-build-number review checks: {pass_n} passed, {fail_n} failed")
    return 0 if fail_n == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
