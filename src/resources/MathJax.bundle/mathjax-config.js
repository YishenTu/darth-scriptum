window.MathJax = {
  startup: {
    typeset: false
  },
  options: {
    enableMenu: false
  },
  tex: {
    maxBuffer: 32768,
    maxTemplateSubstitutions: 10000,
    packages: {
      "[-]": [
        "require",
        "setoptions",
        "html",
        "noerrors",
        "noundefined"
      ]
    }
  },
  svg: {
    fontCache: "local"
  }
};
