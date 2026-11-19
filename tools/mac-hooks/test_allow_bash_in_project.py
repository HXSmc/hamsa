import os, subprocess, tempfile, unittest, sys
sys.path.insert(0, os.path.dirname(__file__))
from allow_bash_in_project import decide

class T(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.tmp = tempfile.TemporaryDirectory()
        cls.root = os.path.realpath(cls.tmp.name) + "/proj"
        os.makedirs(cls.root + "/build/sub")
        subprocess.run(["git", "init", "-q", cls.root], check=True)
    @classmethod
    def tearDownClass(cls): cls.tmp.cleanup()
    def ok(self, cmd, cwd=None): self.assertEqual(decide(cmd, cwd or self.root), "allow", cmd)
    def no(self, cmd, cwd=None): self.assertIsNone(decide(cmd, cwd or self.root), cmd)

    def test_non_rm_allowed(self):
        self.ok("ls -la; git status && swift build")
        self.ok("curl -s example.com | jq .")
    def test_rm_inside(self):
        self.ok("rm -rf build")
        self.ok("rm -rf build/*")
        self.ok("rm -f ./build/sub/x.o build/y.o")
        self.ok("rm -rf *.wav")
        self.ok("rm -rf build/*/*")
        self.ok("cd build && rm -rf sub")
        self.ok("rm -rf sub", cwd=self.root + "/build")
        self.ok(f"rm -rf {self.root}/build")
    def test_rm_outside(self):
        self.no("rm -rf /tmp/x")
        self.no("rm -rf ~/Desktop")
        self.no("rm -rf ..")
        self.no("rm -rf ../other")
        self.no("rm -rf .")
        self.no(f"rm -rf {self.root}")
        self.no("rm -rf .git")
        self.no("rm -rf .g*")
        self.no("rm -rf *")  # can it match .git? no ('*' skips dotfiles in fnmatch? it does match) -> deferred
        self.no("rm -rf $DIR/x")
        self.no("rm -rf `pwd`/x")
        self.no("rm -rf */x")
        self.no("rm -rf build/*/../../..")
        self.no("cd .. && rm -rf proj")
        self.no("rm -rf")
    def test_rm_hidden(self):
        self.no("sudo rm -rf build")
        self.no("find . | xargs rm")
        self.no("bash -c 'rm -rf build'")
        self.no("/bin/rm -rf /etc")
        self.ok("/bin/rm -rf build")
    def test_home_not_project(self):
        self.no("rm -rf foo", cwd=os.path.expanduser("~"))
    def test_bad_quotes(self):
        self.no("rm -rf 'build")

unittest.main(verbosity=1)
