#!/usr/bin/env python3
"""Prepare upstream SQL against a read-only schema; never execute data queries."""
import argparse
import json
from pathlib import Path
import re
import sqlite3

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('checkout', type=Path)
parser.add_argument('database', type=Path, nargs='?')
args = parser.parse_args()
source = (args.checkout / 'src/t3db/sql.rs').read_text()
macros = dict(re.findall(r'macro_rules! (\w+)\s*\{\s*\(\)\s*=>\s*\{(.*?)\};\s*\}', source, re.S))
tokens = re.compile(r'"(?:\\.|[^"\\])*"|([a-z_]+)!\(\)', re.S)
def expand(expression):
    return ''.join(expand(macros[m.group(1)]) if m.group(1) else json.loads(m.group(), strict=False) for m in tokens.finditer(expression))
queries = re.findall(r'pub\(crate\) const (\w+): &str = (.*?);\n', source, re.S)
assert queries, 'No SQL constants found'
if args.database:
    connection = sqlite3.connect(args.database.resolve().as_uri() + '?mode=ro', uri=True)
else:
    connection = sqlite3.connect(':memory:')
    fixture = (args.checkout / 'src/t3db/mod.rs').read_text().split('fn projection_queries_preserve_json_and_scope()', 1)[1]
    fixture = fixture.split('db.execute_batch(r#"', 1)[1].split('"#).unwrap()', 1)[0]
    connection.executescript(fixture)
    for table in ['projection_threads', 'projection_thread_messages', 'projection_thread_activities']:
        connection.execute('DROP TABLE ' + table)
connection.execute('PRAGMA query_only=ON')
for name, expression in queries:
    sql = expand(expression)
    count = max([int(n) for n in re.findall(r'\?(\d+)', sql)], default=0)
    connection.execute('EXPLAIN ' + sql, [None] * count).close()
    print('PASS', name)
if not args.database:
    sql = {name: expand(expression) for name, expression in queries}
    def rows(name, *parameters):
        return connection.execute(sql[name], parameters).fetchall()
    assert len(rows('MESSAGES', 't', 10)) == 2
    assert rows('IMAGES', 't', 'call') == []
    assert rows('IMAGES', 't', 'toolu_2') == [('image/png', 'BBBB')]
    assert len(rows('PROJECT_SCREENSHOTS', 'p')) == 1
    assert len(rows('THREAD_LINKS', 't', 'rival reply', 'rival reply')) == 0
    assert len(rows('THREAD_LINKS', 'u', 'rival reply', 'rival reply')) == 1
    assert rows('PROJECT', 'r') == []
    assert len(rows('SEARCH', 'p', None, '["test_name"]', True, True, True)) == 4
    assert rows('SEARCH', 'p', None, "[\"' OR 1=1 --\"]", True, True, True) == []
    print('PASS V2 fixture: thread/project scope, images, messages, literal search; legacy tables absent')
connection.close()
print(f'Prepared {len(queries)} SQL constants; live database checks use EXPLAIN only.')
