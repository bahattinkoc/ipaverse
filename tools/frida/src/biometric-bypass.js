var ye = de(() => {
  U();
  ae();
  $.available && $.classes.LAContext
    ? ((Y = $.classes.LAContext["- evaluatePolicy:localizedReason:reply:"]),
      Y
        ? (Interceptor.attach(Y.implementation, {
            onEnter: function (e) {
              var t = new $.Block(e[4]),
                n = t.implementation;
              t.implementation = function (r, o) {
                return (
                  send("[biometric-bypass] evaluatePolicy -> forcing success"),
                  n(1, NULL)
                );
              };
            },
          }),
          send("[biometric-bypass] LAContext hook installed"))
        : send(
            "[biometric-bypass] evaluatePolicy:localizedReason:reply: not found",
          ))
    : send("[biometric-bypass] LAContext not present in this process");
  var Y;
});
ye();
