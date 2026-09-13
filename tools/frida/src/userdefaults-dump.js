var ze = Ce(() => {
  x();
  me();
  if (!B.available)
    send({
      type: "log",
      text: "Objective-C runtime not available in this process",
    });
  else {
    let e = function () {
      recv("write-userdefault", function (t) {
        try {
          var n = B.classes.NSUserDefaults.standardUserDefaults(),
            r;
          if (t.valueType === "number")
            if (/^-?\d+$/.test(t.value))
              r = B.classes.NSNumber.numberWithLongLong_(parseInt(t.value, 10));
            else {
              var o = parseFloat(t.value);
              if (isNaN(o)) throw new Error("Not a valid number: " + t.value);
              r = B.classes.NSNumber.numberWithDouble_(o);
            }
          else r = B.classes.NSString.stringWithString_(t.value);
          (n.setObject_forKey_(r, B.classes.NSString.stringWithString_(t.key)),
            n.synchronize(),
            send({
              type: "value-updated",
              requestId: t.requestId,
              key: t.key,
              value: t.value,
              success: !0,
            }));
        } catch (a) {
          send({
            type: "value-updated",
            requestId: t.requestId,
            key: t.key,
            success: !1,
            error: String(a),
          });
        }
        e();
      });
    };
    for (
      e(),
        ge = B.classes.NSUserDefaults.standardUserDefaults(),
        te = ge.dictionaryRepresentation(),
        re = te.allKeys(),
        ne = re.count(),
        send({
          type: "log",
          text: ne + " keys in NSUserDefaults.standardUserDefaults",
        }),
        V = 0;
      V < ne;
      V++
    ) {
      ((oe = re.objectAtIndex_(V)), (J = te.objectForKey_(oe)));
      try {
        D = J.toString();
      } catch (t) {
        D = "<describe failed: " + t + ">";
      }
      (D.length > 500 && (D = D.substring(0, 500) + "\u2026"),
        (_e = J.isKindOfClass_(B.classes.NSString)),
        (se = J.isKindOfClass_(B.classes.NSNumber)),
        (he = _e || se),
        (ye = se ? "number" : "string"),
        send({
          type: "dump-entry",
          fields: [{ k: oe.toString(), v: D }],
          editable: he,
          valueType: ye,
        }));
    }
  }
  var ge, te, re, ne, oe, J, D, _e, se, he, ye, V;
});
ze();
