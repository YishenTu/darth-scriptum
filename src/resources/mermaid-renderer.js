(() => {
  "use strict";

  const maximumSourceLength = 65536;
  const maximumSVGLength = 4 * 1024 * 1024;
  const maximumDimension = 8192;
  const maximumArea = 32 * 1024 * 1024;
  const maximumRasterPixels = 12 * 1024 * 1024;
  const maximumPNGLength = 24 * 1024 * 1024;
  const renderTimeoutMilliseconds = 5000;
  const forbiddenElements = new Set([
    "foreignobject",
    "iframe",
    "image",
    "object",
    "script"
  ]);
  let renderSequence = 0;

  function finitePositive(value) {
    return Number.isFinite(value) && value > 0;
  }

  function withTimeout(promise) {
    let timeoutID;
    const timeout = new Promise((_, reject) => {
      timeoutID = setTimeout(
        () => reject(new Error("render-timeout")),
        renderTimeoutMilliseconds
      );
    });
    return Promise.race([promise, timeout])
      .finally(() => clearTimeout(timeoutID));
  }

  function hasExternalCSS(value) {
    return /@import|url\s*\(\s*["']?(?:https?:|\/\/)/i.test(value);
  }

  function sanitize(svg) {
    for (const element of Array.from(svg.querySelectorAll("*"))) {
      const elementName = element.localName.toLowerCase();
      if (elementName === "a") {
        element.replaceWith(...element.childNodes);
        continue;
      }
      if (forbiddenElements.has(elementName)) {
        element.remove();
        continue;
      }
      if (elementName === "style" && hasExternalCSS(element.textContent || "")) {
        element.remove();
        continue;
      }

      for (const attribute of Array.from(element.attributes)) {
        const name = attribute.localName.toLowerCase();
        const value = attribute.value.trim();
        if (name.startsWith("on")) {
          element.removeAttributeNode(attribute);
          continue;
        }
        if (
          (name === "href" || name === "xlink:href" || name === "src")
          && !value.startsWith("#")
        ) {
          element.removeAttributeNode(attribute);
          continue;
        }
        if (name === "style" && hasExternalCSS(value)) {
          element.removeAttributeNode(attribute);
        }
      }
    }
  }

  function dimensions(svg) {
    const viewBox = svg.viewBox && svg.viewBox.baseVal;
    if (
      viewBox
      && finitePositive(viewBox.width)
      && finitePositive(viewBox.height)
    ) {
      return {width: viewBox.width, height: viewBox.height};
    }

    const bounds = svg.getBoundingClientRect();
    return {width: bounds.width, height: bounds.height};
  }

  function normalizeTextBaselines(svg) {
    for (const text of Array.from(svg.querySelectorAll("text"))) {
      let originalBounds;
      try {
        originalBounds = text.getBBox();
      } catch {
        continue;
      }

      const baselineElements = [
        text,
        ...Array.from(text.querySelectorAll("tspan"))
      ];
      for (const element of baselineElements) {
        element.removeAttribute("dominant-baseline");
        element.removeAttribute("alignment-baseline");
        element.style.setProperty("dominant-baseline", "auto");
        element.style.setProperty("alignment-baseline", "baseline");
      }

      let normalizedBounds;
      try {
        normalizedBounds = text.getBBox();
      } catch {
        continue;
      }

      const verticalOffset = originalBounds.y - normalizedBounds.y;
      if (!Number.isFinite(verticalOffset) || Math.abs(verticalOffset) < 0.01) {
        continue;
      }

      const existingTransform = text.getAttribute("transform");
      const translation = `translate(0 ${verticalOffset})`;
      text.setAttribute(
        "transform",
        existingTransform
          ? `${existingTransform} ${translation}`
          : translation
      );
    }
  }

  function rasterDimensions(width, height) {
    const scale = Math.min(
      2,
      maximumDimension / width,
      maximumDimension / height,
      Math.sqrt(maximumRasterPixels / (width * height))
    );
    return {
      width: Math.max(1, Math.floor(width * scale)),
      height: Math.max(1, Math.floor(height * scale))
    };
  }

  function rasterize(serializedSVG, width, height) {
    const rasterSize = rasterDimensions(width, height);
    return new Promise((resolve, reject) => {
      const blob = new Blob([serializedSVG], {type: "image/svg+xml"});
      const objectURL = URL.createObjectURL(blob);
      const image = new Image();

      image.onload = () => {
        try {
          const canvas = document.createElement("canvas");
          canvas.width = rasterSize.width;
          canvas.height = rasterSize.height;
          const context = canvas.getContext("2d", {alpha: true});
          if (!context) {
            reject(new Error("raster-context-unavailable"));
            return;
          }
          context.clearRect(0, 0, canvas.width, canvas.height);
          context.drawImage(image, 0, 0, canvas.width, canvas.height);
          const png = canvas.toDataURL("image/png");
          if (
            !png.startsWith("data:image/png;base64,")
            || png.length > maximumPNGLength
          ) {
            reject(new Error("raster-output-too-large"));
            return;
          }
          resolve({
            png,
            pixelWidth: rasterSize.width,
            pixelHeight: rasterSize.height
          });
        } catch (error) {
          reject(error);
        } finally {
          URL.revokeObjectURL(objectURL);
        }
      };
      image.onerror = () => {
        URL.revokeObjectURL(objectURL);
        reject(new Error("raster-image-failed"));
      };
      image.src = objectURL;
    });
  }

  window.renderMermaid = async (source) => {
    const target = document.getElementById("render-target");
    try {
      if (
        typeof source !== "string"
        || source.trim().length === 0
        || source.length > maximumSourceLength
      ) {
        return {error: "invalid-input"};
      }
      if (!window.mermaid || typeof window.mermaid.render !== "function") {
        return {error: "renderer-unavailable"};
      }

      target.replaceChildren();
      renderSequence += 1;
      const id = `mermaid-diagram-${renderSequence}`;
      const rendered = await withTimeout(window.mermaid.render(id, source, target));
      target.innerHTML = rendered.svg;

      const svg = target.querySelector("svg");
      if (!svg) {
        return {error: "missing-svg"};
      }
      const {width, height} = dimensions(svg);
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
      normalizeTextBaselines(svg);
      svg.setAttribute("xmlns", "http://www.w3.org/2000/svg");
      svg.setAttribute("width", `${width}px`);
      svg.setAttribute("height", `${height}px`);
      svg.removeAttribute("style");

      const serialized = new XMLSerializer().serializeToString(svg);
      if (serialized.length > maximumSVGLength) {
        return {error: "output-too-large"};
      }
      const raster = await withTimeout(rasterize(serialized, width, height));
      return {svg: serialized, width, height, ...raster};
    } catch (error) {
      const message = String(error && error.message ? error.message : error);
      if (message === "render-timeout") {
        return {error: "render-timeout"};
      }
      return {error: "invalid-diagram"};
    } finally {
      target.replaceChildren();
      for (const errorNode of document.querySelectorAll("[id^='dmermaid-']")) {
        errorNode.remove();
      }
    }
  };

  window.mermaid.initialize({
    startOnLoad: false,
    securityLevel: "strict",
    suppressErrorRendering: true,
    htmlLabels: false,
    maxTextSize: maximumSourceLength,
    maxEdges: 1000,
    deterministicIds: true,
    theme: "base",
    themeVariables: {
      background: "transparent",
      primaryColor: "#2A221E",
      primaryTextColor: "#E8D5B7",
      primaryBorderColor: "#C4956A",
      secondaryColor: "#1A1614",
      secondaryTextColor: "#E8D5B7",
      secondaryBorderColor: "#A9967D",
      tertiaryColor: "#4A3A2A",
      tertiaryTextColor: "#E8D5B7",
      tertiaryBorderColor: "#A9967D",
      lineColor: "#A9967D",
      textColor: "#E8D5B7",
      mainBkg: "#2A221E",
      nodeBorder: "#C4956A",
      clusterBkg: "#1A1614",
      clusterBorder: "#5A4638",
      edgeLabelBackground: "#1A1614",
      fontFamily: "SF Mono, Menlo, monospace"
    },
    flowchart: {
      htmlLabels: false,
      useMaxWidth: false
    }
  });
})();
