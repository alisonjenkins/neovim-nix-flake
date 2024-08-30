import nox


@nox.session(python=False)
def tests(session):
    session.run("pytest")


@nox.session(python=False)
def lint(session):
    session.run("black", "--check", "--diff", ".")
