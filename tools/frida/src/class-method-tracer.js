var we = _e(() => {
  x();
  de();
  var $ = "{{CLASS_NAME}}",
    K = "{{METHOD_FILTER}}",
    Ne = [
      "- dealloc",
      "- retain",
      "- release",
      "- autorelease",
      "- retainCount",
      "- hash",
      "- isEqual:",
      "- description",
      "- debugDescription",
      "- .cxx_destruct",
      "- copy",
      "- copyWithZone:",
      "- init",
    ];
  function pe(e, t) {
    switch (e) {
      case "pointer":
        return t.isNull() ? "nil" : t.toString();
      case "bool":
        return t.toInt32() !== 0 ? "true" : "false";
      case "int8":
      case "uint8":
      case "int16":
      case "uint16":
      case "int":
      case "uint":
      case "int32":
      case "uint32":
        return String(t.toInt32());
      case "int64":
      case "uint64":
        return t.toString();
      case "float":
      case "double":
        return "<" + e + ", not readable this way>";
      case "void":
        return "void";
      default:
        return "<" + e + ">";
    }
  }
  G.available
    ? G.classes[$]
      ? ((ee = G.classes[$]),
        (te = ee.$ownMethods),
        (re = 0),
        te.forEach(function (e) {
          if (K) {
            if (e.indexOf(K) === -1) return;
          } else if (Ne.indexOf(e) !== -1) return;
          try {
            var t = ee[e],
              n = t.argumentTypes,
              r = t.returnType,
              o = t.implementation;
            (Interceptor.attach(o, {
              onEnter: function (i) {
                for (var l = [], u = 2; u < n.length; u++)
                  l.push(pe(n[u], i[u]));
                send("[trace] " + $ + e + "(" + l.join(", ") + ")");
              },
              onLeave: function (i) {
                r !== "void" && send("[trace]   -> " + pe(r, i));
              },
            }),
              re++);
          } catch {}
        }),
        send(
          "[trace] hooked " +
            re +
            "/" +
            te.length +
            " methods on " +
            $ +
            (K ? ' (filter: "' + K + '")' : " (default noise filter applied)"),
        ))
      : send("[trace] class not found: " + $)
    : send("[trace] Objective-C runtime not available in this process");
  var ee, te, re;
});
we();
