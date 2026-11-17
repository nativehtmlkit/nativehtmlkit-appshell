"""Create a disposable AppShell home with the showcase test extension staged (test tooling).

usage: python prepare_home.py py|ps HOME
  py: generates a Python project from python/tests/showcase_extension.py and stages it
  ps: prints the PowerShell showcase module path (stage it with Add-AppShellExtension)
"""
import shutil
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
edition, home = sys.argv[1], Path(sys.argv[2]).resolve()
if home.exists():
    shutil.rmtree(home)
if edition == "py":
    sys.path.insert(0, str(ROOT / "python" / "tests"))
    from showcase_extension import SHOWCASE
    from nativehtmlkit_appshell.scaffold import generate_python
    from nativehtmlkit_appshell.storage import Store
    project = generate_python("org.example.showcase", home.parent / (home.name + "-showcase-src"), title="Showcase") \
        if not (home.parent / (home.name + "-showcase-src")).exists() else home.parent / (home.name + "-showcase-src")
    (next((project / "src").iterdir()) / "__init__.py").write_text(SHOWCASE, encoding="utf-8")
    store = Store(home)
    store.prepare()
    print(store.stage(str(project)))
else:
    print(ROOT / "powershell" / "tests" / "Showcase")
