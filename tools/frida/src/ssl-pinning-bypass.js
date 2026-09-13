function findSecurityExport(name) {
  try {
    return Process.getModuleByName("Security").findExportByName(name);
  } catch (e) {
    return null;
  }
}

var evalWithError = findSecurityExport("SecTrustEvaluateWithError");
if (evalWithError) {
  Interceptor.replace(
    evalWithError,
    new NativeCallback(
      function (trust, error) {
        send("[ssl-pinning-bypass] SecTrustEvaluateWithError -> true");
        return 1;
      },
      "bool",
      ["pointer", "pointer"],
    ),
  );
  send("[ssl-pinning-bypass] hooked SecTrustEvaluateWithError");
}
var evalLegacy = findSecurityExport("SecTrustEvaluate");
if (evalLegacy) {
  Interceptor.replace(
    evalLegacy,
    new NativeCallback(
      function (trust, result) {
        send("[ssl-pinning-bypass] SecTrustEvaluate -> kSecTrustResultProceed");
        if (result && !result.isNull()) {
          result.writeU32(1);
        }
        return 0;
      },
      "int",
      ["pointer", "pointer"],
    ),
  );
  send("[ssl-pinning-bypass] hooked SecTrustEvaluate");
}
if (!evalWithError && !evalLegacy) {
  send("[ssl-pinning-bypass] no SecTrust export found");
}
