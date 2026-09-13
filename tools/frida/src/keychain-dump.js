var Te = Ce(() => {
  U();
  ae();
  function x(e) {
    var t = Process.getModuleByName("Security"),
      n = t.findExportByName(e);
    return n ? new R.Object(n.readPointer()) : null;
  }
  if (!R.available)
    send({
      type: "log",
      text: "Objective-C runtime not available in this process",
    });
  else {
    let e = function (n) {
        if (!n) return null;
        try {
          return n.toString();
        } catch {
          return "<undescribable>";
        }
      },
      t = function (n, r) {
        var o = R.classes.NSMutableDictionary.alloc().init();
        (o.setObject_forKey_(n, le),
          o.setObject_forKey_(R.classes.NSNumber.numberWithBool_(1), de),
          o.setObject_forKey_(fe, pe));
        var a = Memory.alloc(Process.pointerSize);
        a.writePointer(NULL);
        var l = be(o.handle, a);
        if (l !== 0) {
          send({ type: "log", text: r + ": none found (status " + l + ")" });
          return;
        }
        var u = a.readPointer();
        if (u.isNull()) {
          send({ type: "log", text: r + ": none found" });
          return;
        }
        var s = new R.Object(u),
          i = s.isKindOfClass_(R.classes.NSArray),
          c = i ? s : R.classes.NSArray.arrayWithObject_(s),
          g = c.count();
        send({ type: "log", text: r + ": " + g + " item(s)" });
        for (var h = 0; h < g; h++)
          try {
            var p = c.objectAtIndex_(h),
              _ = e(p.objectForKey_(me)),
              b = e(p.objectForKey_(ge)),
              k = e(p.objectForKey_(he)),
              j = e(p.objectForKey_(_e)),
              w = [];
            (_ && w.push({ k: "account", v: _ }),
              b && w.push({ k: "service", v: b }),
              k && w.push({ k: "server", v: k }),
              j && w.push({ k: "label", v: j }),
              w.length === 0 &&
                w.push({ k: "note", v: "(no readable attributes)" }),
              send({ type: "dump-entry", category: r, fields: w }));
          } catch (z) {
            send({ type: "log", text: "  <item " + h + " failed: " + z + ">" });
          }
      };
    ((le = x("kSecClass")),
      (ce = x("kSecClassGenericPassword")),
      (ue = x("kSecClassInternetPassword")),
      (de = x("kSecReturnAttributes")),
      (pe = x("kSecMatchLimit")),
      (fe = x("kSecMatchLimitAll")),
      (me = x("kSecAttrAccount")),
      (ge = x("kSecAttrService")),
      (he = x("kSecAttrServer")),
      (_e = x("kSecAttrLabel")),
      (ye = Process.getModuleByName("Security").findExportByName(
        "SecItemCopyMatching",
      )),
      (be = new NativeFunction(ye, "int", ["pointer", "pointer"])),
      send({
        type: "log",
        text: "listing item attributes \u2014 NOT decrypted values (see note below)",
      }),
      t(ce, "Generic Password (genp)"),
      t(ue, "Internet Password (inet)"),
      send({
        type: "log",
        text: "done. Secret VALUES aren't fetched here \u2014 kSecReturnData reliably failed with errSecParam(-50) against this exact query shape in testing; rather than ship something unreliable, this only surfaces which accounts/services have stored items. If you need the actual secret for one, query it individually with kSecMatchLimit=1 for that specific account.",
      }));
  }
  var le, ce, ue, de, pe, fe, me, ge, he, _e, ye, be;
});
Te();
