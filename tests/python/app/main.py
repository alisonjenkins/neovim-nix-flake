#!/usr/bin/env python3
from requests import get


def add(a, b):
    return a + b


def get_my_ip_info():
    return "== My IP Info ==\n{}".format(get("https://api.my-ip.io/v2/ip.txt").text)


def main():
    print(add(1, 1))
    print()
    print(get_my_ip_info())


if __name__ == "__main__":
    main()
