var Se = pe(() => {
  U();
  ae();
  var be = [
    "/Applications/Cydia.app",
    "/Library/MobileSubstrate/MobileSubstrate.dylib",
    "/bin/bash",
    "/usr/sbin/sshd",
    "/etc/apt",
    "/private/var/lib/apt/",
    "/private/var/lib/cydia",
    "/private/var/stash",
  ];
  function le(e) {
    return (
      e &&
      be.some(function (t) {
        return e.indexOf(t) !== -1;
      })
    );
  }
  ["fopen", "access", "stat", "lstat"].forEach(function (e) {
    var t = Module.findGlobalExportByName(e);
    t &&
      Interceptor.attach(t, {
        onEnter: function (r) {
          this.path = r[0].readCString();
        },
        onLeave: function (r) {
          le(this.path) &&
            (send("[jb-bypass] " + e + "(" + this.path + ") -> denied"),
            r.replace(ptr(e === "fopen" ? 0 : -1)));
        },
      });
  });
  V.available &&
    ((Y = V.classes.NSFileManager["- fileExistsAtPath:"]),
    Y &&
      Interceptor.attach(Y.implementation, {
        onEnter: function (e) {
          this.path = new V.Object(e[2]).toString();
        },
        onLeave: function (e) {
          le(this.path) &&
            (send("[jb-bypass] fileExistsAtPath: " + this.path + " -> false"),
            e.replace(0));
        },
      }));
  var Y;
  send("[jb-bypass] hooks installed");
});
Se();
