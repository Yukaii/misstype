"""Compare real Swift and Zig CLI invocations on isolated synthetic files."""
import os
from pathlib import Path
import subprocess
import sys
import tempfile


def run(swift, zig):
    binaries = [str(Path(p).resolve()) for p in (swift, zig)]
    with tempfile.TemporaryDirectory(prefix='misstype-cli-') as temp:
        root = Path(temp)
        dirs = [root/'swift', root/'zig']
        for d in dirs:
            d.mkdir()
            (d/'dict').write_text('# mine\nㄋㄧˇ-ㄏㄠˇ\t你好\n')
            (d/'conf').write_text('# keep\nOther=1\nAutoShowCandidates=True\n')
            (d/'bad').write_text('bad row\n你好 ㄋㄧˇ-ㄏㄠˇ\n')
        commands = [
            ['help'], [], ['oops'], ['dict'], ['config'],
            ['dict','list','--tsv'],
            ['dict','add','ㄏㄨㄤˊ-ㄩˋ-ㄎㄞˇ','黃昱愷'],
            ['dict','add','ㄏㄨㄤˊ-ㄩˋ-ㄎㄞˇ','黃昱愷'],
            ['dict','list'], ['dict','list','--tsv'],
            ['dict','add','ㄋㄧˇ-ㄏㄠˇ','你'],
            ['dict','add','ㄉㄚˇ-ㄉㄨㄟˋ','打對','--weight','-2'],
            ['dict','exclude','ㄉㄚˇ-ㄉㄨㄟˋ','打對'],
            ['dict','list','--tsv'],
            ['dict','add','ㄉㄚˇ-ㄉㄨㄟˋ','打對','--weight','-1'],
            ['dict','remove','ㄉㄚˇ-ㄉㄨㄟˋ','打對'],
            ['dict','remove','ㄉㄚˇ-ㄉㄨㄟˋ','打對'],
            ['dict','unexclude','ㄉㄚˇ-ㄉㄨㄟˋ','打對'],
            ['dict','exclude','ㄉㄚˇ-ㄉㄨㄟˋ','打對'],
            ['dict','exclude','ㄉㄚˇ-ㄉㄨㄟˋ','打對'],
            ['dict','unexclude','ㄉㄚˇ-ㄉㄨㄟˋ','打對'],
            ['dict','check'], ['dict','check','--file','{dir}/bad'],
            ['dict','add','ㄋㄧˇ','👨‍👩‍👧‍👦'], ['dict','list','--tsv'],
            ['dict','add','ㄋㄧˇ','e\u0301'], ['dict','add','ㄋㄧˇ','é'], ['dict','remove','ㄋㄧˇ','é'], ['dict','check'],
            ['dict','add','ㄋㄧˇ','你','--weight','NaN'],
            ['dict','remove','ㄋㄧˇ','你','--weight','-2'],
            ['dict','list','--what'], ['dict','list','--file'],
            ['config','list'], ['config','get','autoshowcandidates'],
            ['config','set','autoshowcandidates','off'],
            ['config','set','RepairStrength','light'], ['config','set','CursorCandidates','endingat'],
            ['config','set','AutoCommitSyllables','12'], ['config','set','CandidatesPerPage','10'],
            ['config','set','CandidateKeys','1234567890'], ['config','get','CandidateKeys'],
            ['config','set','ShiftTogglesEnglish','on'], ['config','list'],
            ['config','set','CandidateKeys','1234567890-'], ['config','set','CandidateKeys','aab'],
            ['config','set','CandidateKeys','ASDF'], ['config','set','ToneTolerance','maybe'],
            ['config','set','CandidatesPerPage','3'], ['config','set','AutoCommitSyllables','999'],
            ['config','set','RepairStrength','max'], ['config','set','Nope','1'], ['config','get','FuzzyRepair'],
            ['config','reset','AutoCommitSyllables'], ['config','get','AutoCommitSyllables'],
            ['config','reset','AutoCommitSyllables'], ['config','path'], ['dict','path'],
            ['dict','edit'], ['dict','gui'],
        ]
        for command in commands:
            outcomes=[]
            for binary,d in zip(binaries,dirs):
                args=[x.replace('{dir}',str(d)) for x in command]
                if args and args[0] in ('dict','config') and len(args)>1:
                    if '--file' not in args:
                        args += ['--file',str(d/('dict' if args[0]=='dict' else 'conf'))]
                    if args[0]=='config' and args[1] in ('set','reset'):
                        args += ['--no-reload']
                env=dict(os.environ,EDITOR='/bin/true',VISUAL='',XDG_DATA_HOME=str(d/'data'),XDG_CONFIG_HOME=str(d/'config'))
                result=subprocess.run([binary,*args],env=env,text=True,capture_output=True)
                normalize=lambda s:s.replace(str(d),'<dir>')
                outcomes.append((result.returncode,normalize(result.stdout),normalize(result.stderr)))
            assert outcomes[0]==outcomes[1], (command,outcomes)
            for name in ('dict','conf'):
                assert (dirs[0]/name).read_bytes()==(dirs[1]/name).read_bytes(), ('file difference',command,name)
        print(f'PASS {len(commands)} CLI invocations: exit status, stdout/stderr, comments, edits, Unicode, config validation and files match')

if __name__=='__main__':
    run(*sys.argv[1:])
