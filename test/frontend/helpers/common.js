import path from "path";
import mkdirp from "mkdirp";
import * as process from "process";

export const getTextContent = (page, selector) => {
  // https://developer.mozilla.org/en-US/docs/Web/API/Node/textContent#differences_from_innertext
  return page.evaluate(
    (selector) => document.querySelector(selector).innerText,
    selector
  );
};
export const countCells = async (page) =>
  await page.evaluate(() => {
    const a = Array.from(document.querySelectorAll("pluto-cell"));
    return a?.length;
  });

export const paste = async (page, code, selector = "body") => {
  const ret = await page.evaluate(
    (code, selector) => {
      var clipboardEvent = new Event("paste", {
        bubbles: true,
        cancelable: true,
        composed: true,
      });
      clipboardEvent["clipboardData"] = {
        getData: () => code,
      };
      document.querySelector(selector).dispatchEvent(clipboardEvent);
    },
    code,
    selector
  );
  return ret;
};

export const waitForContent = async (page, selector) => {
  await page.waitForSelector(selector, { visible: true });
  await page.waitForFunction(
    (selector) => {
      const element = document.querySelector(selector);
      return element !== null && element.textContent.length > 0;
    },
    { polling: 100 },
    selector
  );
  return getTextContent(page, selector);
};

export const waitForContentToChange = async (
  page,
  selector,
  currentContent
) => {
  await page.waitForSelector(selector, { visible: true });
  await page.waitForFunction(
    (selector, currentContent) => {
      const element = document.querySelector(selector);
      console.log(`element:`, element);
      return element !== null && element.textContent !== currentContent;
    },
    { polling: 100 },
    selector,
    currentContent
  );
  return getTextContent(page, selector);
};

export const waitForContentToBecome = async (page, selector, targetContent) => {
  await page.waitForSelector(selector, { visible: true });
  await page.waitForFunction(
    (selector, targetContent) => {
      const element = document.querySelector(selector);
      // https://developer.mozilla.org/en-US/docs/Web/API/Node/textContent#differences_from_innertext
      return element !== null && element.innerText === targetContent;
    },
    { polling: 100 },
    selector,
    targetContent
  );
  return getTextContent(page, selector);
};

export const clickAndWaitForNavigation = (page, selector) =>
  Promise.all([
    page.waitForNavigation({ waitUntil: "networkidle0" }),
    page.click(selector),
  ]);

const dismissBeforeUnloadDialogs = (page) => {
  page.on("dialog", async (dialog) => {
    if (dialog.type() === "beforeunload") {
      await dialog.accept();
    }
  });
};
const dismissVersionDialogs = (page) => {
  page.on("dialog", async (dialog) => {
    if (
      dialog.message().includes("A new version of Pluto.jl is available! 🎉")
    ) {
      console.info(
        "Ignoring version warning for now (but do remember to update Project.toml!)."
      );
      await dialog.accept();
    }
  });
};

const failOnError = (page) => {
  page.on("console", async (msg) => {
    if (msg.type() === "error" && msg.text().includes("PlutoError")) {
      console.error(`Bad PlutoError - Failing\n${msg.text()}`);
      throw new Error("PlutoError encountered. Let's fix this!");
    }
  });
};


let should_be_offline_input = process.env["PLUTO_TEST_OFFLINE"]?.toLowerCase() ?? "false"
let should_be_offline = [true, 1, "true", "1"].includes(should_be_offline_input)
console.log(`Offline mode enabled: ${should_be_offline}`)

export const setupPage = (page) => {
  failOnError(page);
  dismissBeforeUnloadDialogs(page);
  dismissVersionDialogs(page);
  
  if(should_be_offline) {
    page.setRequestInterception(true);
    page.on("request", (request) => {
      if(["cdn.jsdelivr.net", "unpkg.com", "cdn.skypack.dev", "esm.sh", "firebase.google.com"].some(domain => request.url().includes(domain))) {
        console.error(`Blocking request to ${request.url()}`)
        request.abort();
      } else {
        request.continue();
      }
    });
  }
};

let testname = () => expect.getState().currentTestName.replace(/ /g, "_");

export const lastElement = (arr) => arr[arr.length - 1];

const getFixturesDir = () => path.join(__dirname, "..", "fixtures");

const getArtifactsDir = () => path.join(__dirname, "..", "artifacts");

export const getFixtureNotebookPath = (name) =>
  path.join(getFixturesDir(), name);

export const getTemporaryNotebookPath = () =>
  path.join(
    getArtifactsDir(),
    `temporary_notebook_${testname()}_${Date.now()}.jl`
  );

export const getTestScreenshotPath = () => {
  return path.join(
    getArtifactsDir(),
    `screenshot_${testname()}_${Date.now()}.png`
  );
};

export const saveScreenshot = async (page, screenshot_path) => {
  let dirname = path.dirname(screenshot_path);
  await mkdirp(dirname); // Because some of our tests contain /'s 🤷‍♀️
  await page.screenshot({ path: screenshot_path });
};
