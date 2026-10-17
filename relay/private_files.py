"""Private, no-overwrite development capability files."""
import json
import os
import pathlib
import stat

def private_directory(path):
    path=pathlib.Path(path).resolve()
    fd=os.open(path,os.O_RDONLY|os.O_DIRECTORY|os.O_NOFOLLOW)
    info=os.fstat(fd)
    if info.st_uid!=os.getuid() or stat.S_IMODE(info.st_mode)!=0o700:
        os.close(fd);raise ValueError('private owned directory required')
    return path,fd

def read_private_json(directory,name='provenance.json'):
    _,dfd=private_directory(directory)
    try:
        fd=os.open(name,os.O_RDONLY|os.O_NOFOLLOW,dir_fd=dfd)
        try:
            info=os.fstat(fd)
            if not stat.S_ISREG(info.st_mode) or info.st_uid!=os.getuid() or stat.S_IMODE(info.st_mode)!=0o600 or info.st_size>65536:
                raise ValueError('private bounded file required')
            with os.fdopen(fd,'r') as f:
                fd=None;return json.load(f)
        finally:
            if fd is not None:os.close(fd)
    finally:os.close(dfd)

def write_private_json(directory,name,value):
    _,dfd=private_directory(directory)
    try:
        fd=os.open(name,os.O_WRONLY|os.O_CREAT|os.O_EXCL|os.O_NOFOLLOW,0o600,dir_fd=dfd)
        with os.fdopen(fd,'w') as f:json.dump(value,f)
    finally:os.close(dfd)
