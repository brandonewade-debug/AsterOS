#!/usr/bin/env python3
"""Expose per-client NWParameters, preserving the remote SMB/UNC hostname.
Applied only to pinned SMBClient revision 66eafaa6; never changes process-wide networking.
"""
from pathlib import Path
import sys
root = Path(sys.argv[1]) / 'Sources/SMBClient'
for name in ['Connection', 'Session', 'SMBClient']:
    path = root / (name + '.swift')
    source = path.read_text()
    if 'parameters: NWParameters' in source:
        continue
    source = source.replace('import Foundation', 'import Foundation\nimport Network') if 'import Network' not in source else source
    if name == 'Connection':
        source = source.replace('public init(host: String, port: Int) {', 'public init(host: String, port: Int, parameters: NWParameters = .tcp) {')
        start = source.index('public init(host: String, port: Int, parameters:')
        source = source[:start] + source[start:].replace('NWConnection(to: endpoint, using: .tcp)', 'NWConnection(to: endpoint, using: parameters)', 1)
    elif name == 'Session':
        source = source.replace('public convenience init(host: String, port: Int) {\n    self.init(Connection(host: host, port: port))', 'public convenience init(host: String, port: Int, parameters: NWParameters = .tcp) {\n    self.init(Connection(host: host, port: port, parameters: parameters))')
    else:
        source = source.replace('public init(host: String, port: Int) {', 'public init(host: String, port: Int, parameters: NWParameters = .tcp) {')
        source = source.replace('Session(host: host, port: port)', 'Session(host: host, port: port, parameters: parameters)')
    assert 'parameters: NWParameters' in source, f'{name}: pinned source changed'
    path.write_text(source)
