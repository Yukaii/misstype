"""Synthetic file interoperability and resource-boundary checks through misstype.h.

Runs against the Zig library only. tests/capi/golden/ freezes what the retired
Swift implementation wrote (the three user files after the `learn` and `mark`
scripts) and how it read malformed lexicon rows, so files that real users
created with the Swift IME must keep loading and mean the same thing.
Never reads personal data.
"""
import ctypes as C
import json
import os
from pathlib import Path
import tempfile
import sys

P = C.c_void_p
I = C.c_int32

class Settings(C.Structure):
    _fields_ = [(k, I) for k in ('fuzzy', 'tone', 'learn', 'shift')] + [('keys', C.c_char_p)] + [(k, I) for k in ('autoshow', 'confirm', 'mixed', 'autocommit', 'page', 'cursor')]

class Event(C.Structure):
    _fields_ = [('kind', I), ('label', C.c_char_p), ('text', C.c_char_p), ('mods', C.c_uint32), ('release', I), ('native', I), ('timestamp', C.c_double)]

class Result(C.Structure):
    _fields_ = [('consumed', I), ('commit', P), ('beep', I), ('mode', I)]

class View(C.Structure):
    _fields_ = [('preedit', C.c_char_p), ('bytes', I), ('utf16', I), ('candidates', C.POINTER(C.c_char_p)), ('count', I), ('selected', I), ('keys', C.POINTER(C.c_char_p)), ('key_count', I), ('active', I), ('show', I), ('mark', I), ('mark_start_bytes', I), ('mark_end_bytes', I), ('mark_start', I), ('mark_end', I), ('mark_text', C.c_char_p), ('mark_reading', C.c_char_p)]

class API:
    def __init__(self, path):
        self.lib = C.CDLL(str(Path(path).resolve()))
        signatures = {
            'engine_new': ([C.c_char_p, C.c_char_p], P), 'engine_free': ([P], None),
            'settings_default': ([], Settings), 'engine_set_settings': ([P, C.POINTER(Settings)], None),
            'engine_set_channel_path': ([P, C.c_char_p], None), 'engine_set_channel_learning': ([P, I], None),
            'engine_channel_pair_count': ([P], I), 'engine_clear_channel': ([P], None),
            'engine_set_user_dictionary_path': ([P, C.c_char_p], None),
            'session_new': ([P], P), 'session_free': ([P], None),
            'session_handle': ([P, C.POINTER(Event)], Result), 'session_commit': ([P], P),
            'session_pick': ([P, I], None), 'session_view': ([P], C.POINTER(View)),
            'view_free': ([C.POINTER(View)], None), 'string_free': ([P], None),
        }
        for name, (args, result) in signatures.items():
            f = getattr(self.lib, 'misstype_' + name)
            f.argtypes, f.restype = args, result
            setattr(self, name, f)

class Engine:
    def __init__(self, api, resources, directory):
        self.api = api
        self.directory = directory
        self.engine = api.engine_new(os.fsencode(resources), os.fsencode(directory / 'user_phrases.json'))
        assert self.engine, 'engine creation'
        api.engine_set_channel_path(self.engine, os.fsencode(directory / 'channel_model.json'))
        api.engine_set_channel_learning(self.engine, 1)
        api.engine_set_user_dictionary_path(self.engine, os.fsencode(directory / 'user_dictionary.tsv'))
        self.session = api.session_new(self.engine)
        assert self.session
        self.now = 1000.

    def close(self):
        self.api.session_free(self.session)
        self.api.engine_free(self.engine)

    def send(self, key, mods=0):
        kinds = {'enter': 2, 'tab': 3, 'bs': 4, 'esc': 6, 'left': 7, 'right': 8, 'down': 9}
        kind = kinds.get(key, 0)
        label = key.encode() if kind == 0 else None
        text = label if kind == 0 else b'\r' if key == 'enter' else None
        self.now += .05
        result = self.api.session_handle(self.session, C.byref(Event(kind, label, text, mods, 0, -1, self.now)))
        commit = C.string_at(result.commit).decode() if result.commit else None
        self.api.string_free(result.commit)
        return (result.consumed, commit, result.beep, result.mode)

    def type(self, keys):
        for key in keys:
            self.send(key)

    def view(self):
        ptr = self.api.session_view(self.session)
        assert ptr
        v = ptr.contents
        result = (v.preedit.decode(), v.bytes, v.utf16, [v.candidates[i].decode() for i in range(v.count)], v.selected, v.mark, v.mark_text.decode(), v.mark_reading.decode())
        self.api.view_free(ptr)
        return result

    def top(self, keys):
        self.send('esc'); self.send('esc')
        self.type(keys)
        text = self.view()[0]
        self.send('esc'); self.send('esc')
        return text

    def learn(self):
        self.type('su3'); self.send('tab'); self.send('d')
        assert self.send('enter')[1] == '尼'
        self.type('sm'); self.send('bs'); self.type('u3')
        assert self.send('enter')[1] == '尼'  # learned pick remains the top

    def mark(self):
        self.type('su3cl3')
        self.send('left', 1); self.send('left', 1)
        assert self.view()[5] == 1
        assert self.send('enter')[1] is None
        self.send('esc'); self.send('esc')


def snapshot(directory):
    result = {}
    for name in ('user_phrases.json', 'channel_model.json', 'user_dictionary.tsv'):
        path = directory / name
        if not path.exists():
            continue
        data = path.read_text()
        if name.endswith('.json'):
            data = json.loads(data)
            if name == 'user_phrases.json':
                for entries in data.get('entries', {}).values():
                    for record in entries.values():
                        record.pop('updatedAt', None)
        result[name] = data
    return result


def run(path):
    api = API(path)
    resources = Path('tests/fixtures/lexicon').resolve()
    golden = Path('tests/capi/golden')
    swift_dir = golden / 'swift'
    with tempfile.TemporaryDirectory(prefix='misstype-persist-') as temp:
        root = Path(temp)
        zig_dir = root / 'zig'; zig_dir.mkdir()
        engine = Engine(api, resources, zig_dir)
        try:
            engine.learn(); engine.mark()
            assert api.engine_channel_pair_count(engine.engine) == 1
        finally:
            engine.close()
        assert snapshot(zig_dir) == snapshot(swift_dir), ('generated stores differ from the Swift fixtures', snapshot(zig_dir))
        print('PASS generated phrase, channel and dictionary files have the semantics of the frozen Swift files')

        for source in (swift_dir, zig_dir):
            directory = root / f'cross-{source.name}'; directory.mkdir()
            for file in source.iterdir():
                (directory / file.name).write_bytes(file.read_bytes())
            engine = Engine(api, resources, directory)
            try:
                assert engine.top('su3') == '尼'
                assert api.engine_channel_pair_count(engine.engine) == 1
                engine.type('su3cl3'); engine.send('left', 1); engine.send('left', 1)
                assert engine.view()[5] == 2  # restart sees filed phrase, offers removal
                engine.send('enter'); engine.send('esc'); engine.send('esc')
                # External edit; force a distinct nanosecond mtime without sleeping.
                dictionary = directory / 'user_dictionary.tsv'
                dictionary.write_text('擬好 ㄋㄧˇ-ㄏㄠˇ -0.5\n')
                os.utime(dictionary, ns=(dictionary.stat().st_atime_ns, dictionary.stat().st_mtime_ns + 2_000_000_000))
                assert engine.top('su3cl3') == '擬好'
                dictionary.unlink()
                assert engine.top('su3cl3') == '你好'
                api.engine_clear_channel(engine.engine)
                assert api.engine_channel_pair_count(engine.engine) == 0
                assert json.loads((directory / 'channel_model.json').read_text())['costs'] == {}
            finally:
                engine.close()
        print('PASS Swift-written and Zig-written files: restart, phrase boost, channel load/clear, dictionary removal/mtime reload/deletion')

        for name, phrases in [('legacy', '{"version":1,"entries":{}}'), ('bad', '{invalid'), ('wrong-schema', '{"version":2,"entries":[]}')]:
            directory = root / name; directory.mkdir()
            path = directory / 'user_phrases.json'; path.write_text(phrases)
            (directory / 'channel_model.json').write_text('{bad')
            (directory / 'user_dictionary.tsv').write_text('bad row\nㄋㄧˇ-ㄏㄠˇ\t擬好\t-1\n')
            engine = Engine(api, resources, directory)
            try:
                assert engine.top('su3') == '你'
                assert engine.top('su3cl3') == '擬好'
                assert api.engine_channel_pair_count(engine.engine) == 0
            finally:
                engine.close()
            assert path.read_text() == phrases, 'loading must not overwrite invalid data'
        # A file blocking a parent directory forces writes to fail even as root.
        blocker = root / 'blocked'; blocker.write_text('preserve this sentinel')
        engine = Engine(api, resources, blocker / 'child')
        try:
            engine.learn(); engine.mark()
            assert api.engine_channel_pair_count(engine.engine) == 1
        finally:
            engine.close()
        assert blocker.read_text() == 'preserve this sentinel'
        print('PASS legacy/bad schemas and malformed rows fall back; failed writes preserve existing data and in-memory behavior')

        for payload in [b'\xff', b'\xe4\xbd', b'\xed\xa0\x80']:
            directory = root / f'invalid-{payload.hex()}'; directory.mkdir()
            (directory / 'lexicon.tsv').write_bytes(payload)
            ptr = api.engine_new(os.fsencode(directory), b'')
            if ptr:
                api.engine_free(ptr)
            assert not ptr, 'invalid UTF-8 resource must fail engine creation'
        print('PASS invalid UTF-8 lexicons are refused')

        expected_rows = json.loads((golden / 'swift_rows.json').read_text())
        for case, payload in enumerate([
            'bad row\nㄋㄧˇ\t你\t-5\nㄋㄧˇ\t壞\tnot-a-number\n',
            'ㄋㄧˇ\t壞\tNaN\nㄋㄧˇ\t壞\tinf\nㄋㄧˇ\t你\t-5\n',
            '# comment\r\nㄋㄧˇ\t你\t-5\r\n',
            'ㄋㄧˇ\t你\t-5\nㄋㄧˇ\t你\t-6\n',
            'ㄋㄧˇ\t你\t-5\textra\nㄋㄧˇ\t你\t-6\n',
        ]):
            directory = root / f'rows-{case}'; directory.mkdir()
            resource = directory / 'resources'; resource.mkdir()
            (resource / 'lexicon.tsv').write_text(payload)
            engine = Engine(api, resource, directory)
            try:
                engine.type('su3'); view = list(engine.view())
            finally:
                engine.close()
            assert view == expected_rows[case], ('resource rows', case, view, expected_rows[case])
        print('PASS malformed/duplicate/non-finite/CRLF resource rows match the frozen Swift fallback')

        directory = root / 'canonical-context'; directory.mkdir()
        resource = directory / 'resources'; resource.mkdir()
        (resource / 'lexicon.tsv').write_text('ㄋㄧˇ\té\t-3\nㄏㄠˇ\t好\t-4\nㄏㄠˇ\t豪\t-5\n')
        (directory / 'user_phrases.json').write_text(json.dumps({'version': 2, 'entries': {'e\u0301|ㄏㄠ': {'豪': {'count': 2, 'updatedAt': 0}}}}))
        engine = Engine(api, resource, directory)
        try:
            top = engine.top('su3cl3')
        finally:
            engine.close()
        assert top == 'é豪', ('canonical context learning', top)
        print('PASS canonical Unicode context keys survive restart and score equivalent spellings equally')

if __name__ == '__main__':
    assert len(sys.argv) == 2, 'usage: persistence.py <libMisstypeCAPI.so>'
    run(sys.argv[1])
