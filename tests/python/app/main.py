#!/usr/bin/env python3
from requests import get


def add(a, b):
    return a + b


def get_my_ip_info():
    headers = {
        "Accept": "*/*",
        "Content-Type": "text/plain",
        "User-Agent": "curl/8.9.0",
    }
    return "== My IP Info ==\n{}".format(get("https://myip.dk", headers=headers).text)


def main():
    print(add(1, 1))
    print()
    print(get_my_ip_info())


if __name__ == "__main__":
    main()
