"""Exercise fallback control flow with fictional parent-local children only."""
import pathlib, re, shutil, subprocess, unittest
ROOT=pathlib.Path(__file__).resolve().parents[1]
SOURCE=(ROOT/'Sources/HarborReply/Resources/MailBridge.applescript').read_text()

def handler(name):
    return re.search(rf'^on {name}\(.*?^end {name}$',SOURCE,re.M|re.S).group(0)

@unittest.skipUnless(shutil.which('osascript'),'macOS required')
class MailboxResolutionTests(unittest.TestCase):
    def probe(self,children,wanted,code):
        s=handler('strictEqual')+'\n'+handler('indexChildMailbox')
        s=s.replace('tell application "Mail" to return mailbox wantedName of parentBox',f'error "fixture.invalid" number {code}')
        s=s.replace('tell application "Mail"','tell me').replace('count of mailboxes of parentBox','count of parentBox').replace('mailbox childIndex of parentBox','item childIndex of parentBox').replace('name of candidateBox as text','candidateBox as text')
        s='property readFailureStage : 0\non bodyMetricGet()\nend bodyMetricGet\n'+s
        s+='\non run\ntry\nset found to my indexChildMailbox('+children+', "'+wanted+'")\nreturn "found"\non error number n\nreturn n\nend try\nend run'
        self.assertNotIn('application "Mail"',s)
        r=subprocess.run(['/usr/bin/osascript','-'],input=s,text=True,capture_output=True,timeout=10)
        self.assertEqual(r.returncode,0,r.stderr)
        return r.stdout.strip()
    def test_enumerated_name_is_resolved_after_name_lookup_failure(self):
        self.assertEqual(self.probe('{"parent/child.invalid","Sent"}','parent/child.invalid',-1728),'found')
    def test_wrong_case_missing_and_duplicate_remain_closed(self):
        self.assertEqual(self.probe('{"Sent"}','sent',-1728),'-1728')
        self.assertEqual(self.probe('{"Sent","Sent"}','Sent',-1728),'9130')
    def test_permission_and_timeout_do_not_start_enumeration(self):
        for code in (-1743,-1712):self.assertEqual(self.probe('{"Sent"}','Sent',code),str(code))
