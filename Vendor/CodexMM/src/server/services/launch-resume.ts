import { execFile } from "node:child_process";
import { promisify } from "node:util";

const execFileAsync = promisify(execFile);

export async function launchResumeCommand(command: string) {
  if (process.platform !== "darwin") {
    return false;
  }

  await execFileAsync("osascript", [
    "-e",
    `tell application "Terminal" to do script ${JSON.stringify(command)}`,
    "-e",
    'tell application "Terminal" to activate',
  ]);

  return true;
}
