var Ee = Pe(() => {
  U();
  ye();
  if (!D.available)
    send({
      type: "log",
      text: "Objective-C runtime not available in this process",
    });
  else if (((ne = Module.findGlobalExportByName("NSHomeDirectory")), !ne))
    send({ type: "log", text: "NSHomeDirectory export not found" });
  else {
    let e = function () {
      recv("read-file", function (t) {
        try {
          var n = F.stringByAppendingPathComponent_(t.path),
            r = D.classes.NSData.dataWithContentsOfFile_(n);
          if (!r)
            send({
              type: "file-content",
              requestId: t.requestId,
              path: t.path,
              error: "File not found or unreadable",
            });
          else {
            var o = r.length();
            if (o > oe)
              send({
                type: "file-content",
                requestId: t.requestId,
                path: t.path,
                error:
                  "File too large to transfer (" +
                  o +
                  " bytes, cap is " +
                  oe +
                  ")",
              });
            else {
              var a = r.base64EncodedStringWithOptions_(0).toString();
              send({
                type: "file-content",
                requestId: t.requestId,
                path: t.path,
                base64: a,
                size: o,
              });
            }
          }
        } catch (l) {
          send({
            type: "file-content",
            requestId: t.requestId,
            path: t.path,
            error: String(l),
          });
        }
        e();
      });
    };
    for (
      be = new NativeFunction(ne, "pointer", []),
        F = new D.Object(be()),
        send({ type: "log", text: "container: " + F.toString() }),
        oe = 25 * 1024 * 1024,
        e(),
        Se = [".sqlite", ".sqlite3", ".db", ".realm", ".plist"],
        se = D.classes.NSFileManager.defaultManager(),
        ve = se.enumeratorAtPath_(F),
        J = 0,
        $ = 0,
        Ce = 2e4,
        Q = 200;
      (Z = ve.nextObject()) !== null && J < Ce;
    )
      if (
        (J++,
        (ie = Z.toString()),
        (Ne = ie.toLowerCase()),
        !!Se.some(function (t) {
          return Ne.endsWith(t);
        }) && ($++, !($ > Q)))
      ) {
        ((we = F.stringByAppendingPathComponent_(Z)), (ae = "unknown"));
        try {
          ((le = se.attributesOfItemAtPath_error_(we, NULL)),
            le &&
              ((ce = le.objectForKey_(
                D.classes.NSString.stringWithString_("NSFileSize"),
              )),
              ce && (ae = ce.toString() + " bytes")));
        } catch {}
        send({
          type: "dump-entry",
          fields: [
            { k: "path", v: ie },
            { k: "size", v: ae },
          ],
        });
      }
    send({
      type: "log",
      text:
        "scanned " +
        J +
        " entries under the container, " +
        $ +
        " matched (.sqlite/.sqlite3/.db/.realm/.plist)" +
        ($ > Q ? " \u2014 only the first " + Q + " shown" : ""),
    });
  }
  var ne, be, F, oe, Se, se, ve, J, $, Ce, Q, Z, ie, Ne, we, ae, le, ce;
});
Ee();
