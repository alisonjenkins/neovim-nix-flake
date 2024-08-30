import tempfile

import nox


@nox.session(python=False)
def tests(session):
    with tempfile.TemporaryDirectory() as tempdir:
        session.run("pytest", "-o", f"cache_dir={tempdir}")


@nox.session(python=False)
def lint(session):
    session.run("black", "--check", "--diff", ".")
