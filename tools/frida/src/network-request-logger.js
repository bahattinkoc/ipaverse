var Oe = ye(() => {
  F();
  me();
  if (!M.available) send({ type: "log", text: "ObjC not available" });
  else {
    let e = function () {
        recv("set-intercept", function (i) {
          ((ee = !!i.enabled),
            (W = i.filter || ""),
            send({
              type: "log",
              text:
                "intercept " +
                (ee ? "ON" : "OFF") +
                (W ? ' filter="' + W + '"' : ""),
            }),
            e());
        });
      },
      t = function (i) {
        return ee
          ? W
            ? i.toLowerCase().indexOf(W.toLowerCase()) !== -1
            : !0
          : !1;
      },
      n = function (i) {
        var l = {};
        if (!i) return l;
        for (var u = i.allKeys(), o = u.count(), s = 0; s < o; s++) {
          var c = u.objectAtIndex_(s),
            p = i.objectForKey_(c);
          l[c.toString()] = p ? p.toString() : "";
        }
        return l;
      },
      r = function (i) {
        if (!i) return null;
        try {
          // Keep the original NSData in the target; omit large bodies from IPC.
          if (Number(i.length()) > 32768) return null;
          var l = M.classes.NSString.alloc().initWithData_encoding_(i, 4);
          return l ? l.toString() : null;
        } catch {
          return null;
        }
      },
      a = function (i) {
        return M.classes.NSString.stringWithString_(i).dataUsingEncoding_(4);
      };
    ((ee = !1),
      (W = ""),
      (ge = 0),
      (ie = {}),
      e(),
      (_e = M.classes.NSURLSession),
      (ae = {}),
      [
        { sel: "- dataTaskWithRequest:completionHandler:", hasHandler: !0 },
        { sel: "- dataTaskWithRequest:", hasHandler: !1 },
      ].forEach(function (i) {
        var l = _e[i.sel];
        l &&
          Interceptor.attach(l.implementation, {
            onEnter: function (u) {
              var o = "req-" + ge++;
              this.reqId = o;
              var s = new M.Object(u[2]),
                c = {
                  id: o,
                  method: (s.HTTPMethod() || "GET").toString(),
                  url: s.URL() ? s.URL().absoluteString().toString() : "",
                  headers: n(s.allHTTPHeaderFields()),
                  body: r(s.HTTPBody()),
                },
                p = t(c.url);
              if (p) {
                send(Object.assign({ type: "request-pending" }, c));
                var g = null;
                if (
                  (recv("resume-req-" + o, function (z) {
                    g = z;
                  }).wait(),
                  g.action === "drop")
                ) {
                  var _ = M.classes.NSMutableURLRequest.requestWithURL_(
                    M.classes.NSURL.URLWithString_(
                      "https://0.0.0.0.ipaverse-dropped.invalid/",
                    ),
                  );
                  ((u[2] = _),
                    send({ type: "dropped", id: o, phase: "request" }));
                  return;
                }
                if (g.action !== "continue") {
                var h = s.mutableCopy();
                (h.setURL_(M.classes.NSURL.URLWithString_(g.url)),
                  h.setHTTPMethod_(g.method));
                var b = h.allHTTPHeaderFields();
                if (b)
                  for (var O = b.allKeys(), P = 0; P < O.count(); P++)
                    h.setValue_forHTTPHeaderField_(null, O.objectAtIndex_(P));
                var j = g.headers || {};
                for (var T in j) h.setValue_forHTTPHeaderField_(j[T], T);
                (g.body !== undefined && g.body !== null && h.setHTTPBody_(a(g.body)), (u[2] = h));
                }
              } else send(Object.assign({ type: "request-log" }, c));
              if (i.hasHandler) {
                var H = new M.Block(u[3]),
                  U = H.implementation;
                H.implementation = function (z, L, B) {
                  if (!p) {
                    try {
                      var J = L ? L.statusCode().toString() : null;
                      send({
                        type: "response-log",
                        id: o,
                        status: J,
                        error: B ? B.localizedDescription().toString() : null,
                      });
                    } catch {}
                    U(z, L, B);
                    return;
                  }
                  var q = null,
                    $ = null,
                    V = {};
                  if (L)
                    try {
                      ((q = L.statusCode().toString()),
                        ($ = L.URL()
                          ? L.URL().absoluteString().toString()
                          : null),
                        (V = n(L.allHeaderFields())));
                    } catch {}
                  send({
                    type: "response-pending",
                    id: o,
                    status: q,
                    url: $,
                    headers: V,
                    body: r(z),
                    error: B ? B.localizedDescription().toString() : null,
                  });
                  var R = null;
                  if (
                    (recv("resume-resp-" + o, function (k) {
                      R = k;
                    }).wait(),
                    R.action === "drop")
                  ) {
                    var te = M.classes.NSError.errorWithDomain_code_userInfo_(
                      "NSURLErrorDomain",
                      -999,
                      null,
                    );
                    (send({ type: "log", text: "response dropped for " + o }),
                      U(null, null, te));
                    return;
                  }
                  var Q = z,
                    y = L;
                  if (R.action === "continue") {
                    U(z, L, B);
                    return;
                  }
                  if (
                    (R.body !== void 0 && R.body !== null && (Q = a(R.body)),
                    R.status && $)
                  ) {
                    var d = M.classes.NSMutableDictionary.dictionary(),
                      v = R.headers || {};
                    for (var N in v) d.setObject_forKey_(v[N], N);
                    y =
                      M.classes.NSHTTPURLResponse.alloc().initWithURL_statusCode_HTTPVersion_headerFields_(
                        M.classes.NSURL.URLWithString_($),
                        parseInt(R.status, 10),
                        "1.1",
                        d,
                      );
                  }
                  (send({
                    type: "log",
                    text: "calling original completion with status=" + R.status,
                  }),
                    U(Q, y, B));
                };
              }
            },
            onLeave: function (u) {
              if (!u.isNull())
                try {
                  var o = new M.Object(u),
                    s = o.taskIdentifier().toString();
                  (i.hasHandler && (ae[s] = !0),
                    send({
                      type: "request-sent",
                      id: this.reqId,
                      taskIdentifier: s,
                    }));
                } catch {}
            },
          });
      }),
      (he = M.classes.NSURLSessionTask),
      (le = he["- setState:"]),
      le &&
        Interceptor.attach(le.implementation, {
          onEnter: function (i) {
            var l = i[2].toInt32();
            if (l === 3)
              try {
                var u = new M.Object(i[0]),
                  o = u.taskIdentifier().toString();
                if (ae[o]) { delete ae[o]; return; }
                var s = u.response(),
                  c =
                    s && s.$className === "NSHTTPURLResponse"
                      ? s.statusCode().toString()
                      : null,
                  p = u.error();
                send({
                  type: "response",
                  taskIdentifier: o,
                  status: c,
                  error: p ? p.localizedDescription().toString() : null,
                });
              } catch {}
          },
        }),
      send({
        type: "log",
        text: "network-request-logger active (intercept OFF by default)",
      }));
  }
  var ee, W, ge, ie, _e, ae, he, le;
});
Oe();
