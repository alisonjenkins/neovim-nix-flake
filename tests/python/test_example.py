import re

from app.main import add, get_my_ip_info


def test_add():
    assert add(1, 1) == 2
    assert add(2, 1) == 3


def test_get_ip_info():
    output = get_my_ip_info()
    match = re.match(
        r"== My IP Info ==\n(?P<ip_address>\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}).*",
        output,
    )
    assert match != None
