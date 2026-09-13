var ke = _e(() => {
  B();
  ue();
  if (!T.available) send({ type: "log", text: "ObjC not available" });
  else if (!T.classes.UIApplication || !T.classes.UIWindow)
    send({
      type: "log",
      text: "UIKit not present in this process (not a UIKit app, or it hasn't finished launching yet)",
    });
  else {
    let e = function (o) {
        var c = "v" + de++;
        return ((ee[c] = o), c);
      },
      t = function () {
        recv("highlight-view", function (o) {
          var c = ee[o.viewId];
          if (!c)
            send({
              type: "log",
              text: "highlight: view no longer tracked (re-run the dump)",
            });
          else
            try {
              var s = c.backgroundColor();
              (T.schedule(T.mainQueue, function () {
                try {
                  c.setBackgroundColor_(T.classes.UIColor.systemRedColor());
                } catch (a) {
                  send({
                    type: "log",
                    text: "highlight failed (view likely gone): " + a,
                  });
                }
              }),
                setTimeout(function () {
                  T.schedule(T.mainQueue, function () {
                    try {
                      c.setBackgroundColor_(s);
                    } catch {}
                  });
                }, 1200));
            } catch (a) {
              send({ type: "log", text: "highlight failed: " + a });
            }
          t();
        });
      },
      r = function (o, c) {
        try {
          return typeof o[c] == "function" ? o[c]() : null;
        } catch {
          return null;
        }
      },
      n = function (o, c) {
        try {
          return !!c && o.isKindOfClass_(c);
        } catch {
          return !1;
        }
      },
      i = function (o) {
        try {
          var c = o.frame();
          return { x: c[0][0], y: c[0][1], w: c[1][0], h: c[1][1] };
        } catch {
          return null;
        }
      },
      l = function (o) {
        var c = {
            id: e(o),
            cls: o.$className,
            frame: i(o),
            hidden: !!r(o, "isHidden"),
          },
          s = r(o, "accessibilityIdentifier");
        s && (c.accessibilityIdentifier = s.toString());
        var a = r(o, "accessibilityLabel");
        a && (c.accessibilityLabel = a.toString());
        try {
          if (n(o, T.classes.UITextField)) {
            c.secure = !!r(o, "isSecureTextEntry");
            var u = r(o, "text");
            u && (c.text = u.toString());
            var g = r(o, "placeholder");
            g && (c.placeholder = g.toString());
          } else if (n(o, T.classes.UILabel)) {
            var h = r(o, "text");
            h && (c.text = h.toString());
          } else if (n(o, T.classes.UIButton)) {
            var p = r(o, "currentTitle");
            p && (c.text = p.toString());
          } else if (T.classes.WKWebView && n(o, T.classes.WKWebView)) {
            var _ = r(o, "URL");
            _ && (c.url = _.absoluteString().toString());
          }
        } catch {}
        var b = [];
        try {
          for (var w = o.subviews(), P = w.count(), O = 0; O < P; O++)
            b.push(l(new T.Object(w.objectAtIndex_(O))));
        } catch {}
        return (b.length > 0 && (c.children = b), c);
      };
    ((ee = {}), (de = 0), t());
    try {
      if (
        ((pe = T.classes.UIApplication.sharedApplication()),
        (te = pe.windows()),
        (G = te.count()),
        G === 0)
      )
        send({
          type: "log",
          text: "UIApplication has 0 windows \u2014 app may not have finished launching",
        });
      else
        for (send({ type: "log", text: G + " window(s)" }), F = 0; F < G; F++)
          ((fe = new T.Object(te.objectAtIndex_(F))),
            send({ type: "ui-window", index: F, tree: l(fe) }));
    } catch (o) {
      send({ type: "log", text: "failed: " + o });
    }
  }
  var ee, de, pe, te, G, fe, F;
});
ke();
