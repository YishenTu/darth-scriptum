(() => {
  "use strict";

  const maximumLatexLength = 32768;
  const maximumSVGLength = 2 * 1024 * 1024;
  const maximumDimension = 16384;
  const maximumArea = 64 * 1024 * 1024;
  const renderTimeoutMilliseconds = 5000;
  const forbiddenElements = new Set([
    "foreignobject",
    "iframe",
    "image",
    "object",
    "script"
  ]);

  function parseLength(value, fontSize) {
    if (!value) {
      return Number.NaN;
    }

    const match = String(value)
      .trim()
      .match(/^(-?(?:\d+\.?\d*|\.\d+))(px|em|ex|pt)?$/i);
    if (!match) {
      return Number.NaN;
    }

    const amount = Number(match[1]);
    switch ((match[2] || "px").toLowerCase()) {
      case "em":
        return amount * fontSize;
      case "ex":
        return amount * fontSize * 0.5;
      case "pt":
        return amount * (4 / 3);
      default:
        return amount;
    }
  }

  function sanitize(svg) {
    for (const element of Array.from(svg.querySelectorAll("*"))) {
      if (element.localName.toLowerCase() === "a") {
        element.replaceWith(...element.childNodes);
        continue;
      }
      if (forbiddenElements.has(element.localName.toLowerCase())) {
        element.remove();
        continue;
      }

      for (const attribute of Array.from(element.attributes)) {
        const name = attribute.localName.toLowerCase();
        if (name.startsWith("on")) {
          element.removeAttributeNode(attribute);
          continue;
        }

        if (
          (name === "href" || name === "xlink:href")
          && !attribute.value.startsWith("#")
        ) {
          element.removeAttributeNode(attribute);
        }
      }
    }
  }

  function finitePositive(value) {
    return Number.isFinite(value) && value > 0;
  }

  function loaderDiagnostics() {
    const loader = window.MathJax && window.MathJax.loader;
    if (!loader) {
      return "loader-unavailable";
    }

    const details = {};
    for (const name of ["loading", "loaded", "failed"]) {
      const value = loader[name];
      if (value instanceof Map || value instanceof Set) {
        details[name] = Array.from(value.keys());
      } else if (value && typeof value === "object") {
        details[name] = Object.keys(value);
      }
    }
    return JSON.stringify(details);
  }

  function withTimeout(promise, phase) {
    let timeoutID;
    const timeout = new Promise((_, reject) => {
      timeoutID = setTimeout(
        () => reject(new Error(`${phase}-timeout`)),
        renderTimeoutMilliseconds
      );
    });
    return Promise.race([
      promise,
      timeout
    ]).finally(() => clearTimeout(timeoutID));
  }

  window.renderLatex = async (latex, fontSize, color) => {
    try {
      if (
        typeof latex !== "string"
        || latex.length === 0
        || latex.length > maximumLatexLength
        || !finitePositive(fontSize)
        || fontSize > 512
        || typeof color !== "string"
        || !/^#[0-9a-f]{6}$/i.test(color)
      ) {
        return {error: "invalid-input"};
      }

      await withTimeout(MathJax.startup.promise, "startup");
      const target = document.getElementById("render-target");
      target.style.fontSize = `${fontSize}px`;
      target.style.color = color;
      target.replaceChildren();

      const container = await withTimeout(
        MathJax.tex2svgPromise(latex, {
          display: false,
          em: fontSize,
          ex: fontSize * 0.5,
          containerWidth: Math.min(maximumDimension, fontSize * 80)
        }),
        "typeset"
      );
      target.replaceChildren(container);

      if (container.querySelector('[data-mml-node="merror"]')) {
        return {error: "unsupported-latex"};
      }
      const svg = container.querySelector("svg");
      if (!svg) {
        return {error: "missing-svg"};
      }

      const bounds = svg.getBoundingClientRect();
      const width = bounds.width || parseLength(svg.getAttribute("width"), fontSize);
      const height = bounds.height || parseLength(svg.getAttribute("height"), fontSize);
      const verticalAlign = parseLength(
        svg.style.verticalAlign || getComputedStyle(svg).verticalAlign,
        fontSize
      );
      const baseline = Number.isFinite(verticalAlign)
        ? Math.max(0, -verticalAlign)
        : 0;

      if (
        !finitePositive(width)
        || !finitePositive(height)
        || width > maximumDimension
        || height > maximumDimension
        || width * height > maximumArea
      ) {
        return {error: "invalid-dimensions"};
      }

      sanitize(svg);
      svg.setAttribute("xmlns", "http://www.w3.org/2000/svg");
      svg.setAttribute("width", `${width}px`);
      svg.setAttribute("height", `${height}px`);
      svg.style.color = color;
      svg.style.verticalAlign = "";

      const serialized = new XMLSerializer()
        .serializeToString(svg)
        .replaceAll("currentColor", color);
      if (serialized.length > maximumSVGLength) {
        return {error: "output-too-large"};
      }

      return {
        svg: serialized,
        width,
        height,
        baseline
      };
    } catch (error) {
      const message = error instanceof Error ? error.message : String(error);
      return {
        error: message.includes("timeout")
          ? `${message}: ${loaderDiagnostics()}`
          : message
      };
    }
  };
})();
