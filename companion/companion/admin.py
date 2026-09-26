"""Local-only administration: docker exec asteros-companion python -m companion.admin pair"""
import argparse
import os
from .core import Companion

def main():
    parser=argparse.ArgumentParser()
    parser.add_argument('action',choices=['pair','devices','revoke'])
    parser.add_argument('device',nargs='?')
    args=parser.parse_args()
    core=Companion(os.getenv('ASTEROS_STATE','/data'),os.getenv('ASTEROS_STORAGE','/storage'))
    if args.action == 'pair': print(core.pair_code())
    elif args.action == 'devices':
        with core.connection() as db:
            for row in db.execute('SELECT id,name,revoked FROM devices'): print(row['id'],row['name'],'revoked' if row['revoked'] else 'active')
    elif args.device: core.revoke(args.device)
    else: parser.error('revoke requires a device ID')
if __name__ == '__main__': main()
