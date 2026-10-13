#!/usr/bin/env python3
"""Use fast HTTPS mirrors while retaining the upstream RPM signing key."""
import configparser
from pathlib import Path
import sys


UPSTREAM = 'https://repo.openeuler.org/'
MIRRORS = (
    'https://repo.huaweicloud.com/openeuler/',
    'https://mirrors.nju.edu.cn/openeuler/',
    'https://mirrors.tuna.tsinghua.edu.cn/openeuler/',
    UPSTREAM,
)
BINARY = {'OS', 'everything', 'EPOL', 'update'}


def configure(path):
    config = configparser.ConfigParser(interpolation=None)
    with path.open() as handle:
        config.read_file(handle)
    if not BINARY.issubset(config.sections()):
        raise RuntimeError('openEuler binary repository configuration is incomplete')
    for name in config.sections():
        section = config[name]
        section.pop('metalink', None)
        section['gpgcheck'] = '1'
        if name not in BINARY:
            section['enabled'] = '0'
            continue
        base = section['baseurl']
        if not base.startswith(UPSTREAM) or any(char.isspace() for char in base):
            raise RuntimeError('Unexpected openEuler repository base URL')
        key = section['gpgkey'].replace('http://repo.openeuler.org/', UPSTREAM)
        if not key.startswith(UPSTREAM) or any(char.isspace() for char in key):
            raise RuntimeError('Unexpected upstream RPM signing key URL')
        suffix = base[len(UPSTREAM):]
        section['baseurl'] = '\n'.join(root + suffix for root in MIRRORS)
        section['gpgkey'] = key
        section['enabled'] = '1'
        # Reuse verified metadata between update/install within this build.
        section['metadata_expire'] = '2h'
    with path.open('w') as handle:
        config.write(handle)


if __name__ == '__main__':
    configure(Path(sys.argv[1]))
