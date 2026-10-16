'use strict';

// Offline CLI: --schema <file> followed by YAML files/directories. CI supplies
// AZURE_PIPELINES_LANGUAGE_SERVICE; warnings and errors fail validation except
// the narrow Marketplace-task schema gaps below. Inputs are never executed.
const fs = require('node:fs');
const path = require('node:path');

const servicePath = process.env.AZURE_PIPELINES_LANGUAGE_SERVICE;
if (!servicePath) {
  throw new Error('AZURE_PIPELINES_LANGUAGE_SERVICE must point to the installed language service.');
}

const { parse, getLanguageService, DiagnosticSeverity } = require(servicePath);
// CI supplies the pinned service and schema externally; validation must not
// silently fall back to a different schema or fetch dependencies at runtime.
const args = process.argv.slice(2);
const schemaIndex = args.indexOf('--schema');
if (schemaIndex < 0 || !args[schemaIndex + 1]) {
  throw new Error('Usage: node validate-azure-pipelines.js --schema <schema.json> <file-or-directory> [...]');
}

const schemaPath = args[schemaIndex + 1];
const inputPaths = args.filter((_, index) => index !== schemaIndex && index !== schemaIndex + 1);
if (inputPaths.length === 0) {
  throw new Error('At least one YAML file or directory is required.');
}

const schema = JSON.parse(fs.readFileSync(schemaPath, 'utf8'));
const languageService = getLanguageService(
  async () => schema,
  [],
  undefined
);
languageService.configure({
  validate: true,
  schemas: [{ uri: schema.$id, fileMatch: ['*'], schema }],
});
const files = new Set();
for (const inputPath of inputPaths) {
  const absolutePath = path.resolve(inputPath);
  if (!fs.existsSync(absolutePath)) {
    throw new Error(`Path does not exist: ${inputPath}`);
  }
  const stat = fs.statSync(absolutePath);
  if (stat.isDirectory()) {
    const pending = [absolutePath];
    while (pending.length > 0) {
      const directory = pending.pop();
      for (const entry of fs.readdirSync(directory, { withFileTypes: true })) {
        const entryPath = path.join(directory, entry.name);
        if (entry.isDirectory()) {
          pending.push(entryPath);
        } else if (entry.isFile() && /\.(yml|yaml)$/i.test(entry.name)) {
          files.add(entryPath);
        }
      }
    }
  } else if (/\.(yml|yaml)$/i.test(absolutePath)) {
    files.add(absolutePath);
  } else {
    throw new Error(`Expected a YAML file or directory: ${inputPath}`);
  }
}

if (files.size === 0) {
  throw new Error('No Azure Pipelines YAML files were found.');
}

function getLine(content, offset) {
  return content.slice(0, offset).split(/\r?\n/).length;
}

// The generic schema omits Marketplace task definitions; allow only the extension tasks and inputs used here.
const customTasks = new Set([
  'PowerPlatformToolInstaller@2',
  'ALM4Dataverse.alm4dataverse-azdo-extensions.alm4dataverse-set-connection-variables.ALM4DataverseSetConnectionVariables@1',
  'microsoft-IsvExpTools.PowerPlatform-BuildTools.set-connection-variables.PowerPlatformSetConnectionVariables@2',
]);
const customTaskInputs = new Map([
  ['AddToolsToPath', new Set(['PowerPlatformToolInstaller@2'])],
  ['authenticationType', new Set([
    'ALM4Dataverse.alm4dataverse-azdo-extensions.alm4dataverse-set-connection-variables.ALM4DataverseSetConnectionVariables@1',
    'microsoft-IsvExpTools.PowerPlatform-BuildTools.set-connection-variables.PowerPlatformSetConnectionVariables@2',
  ])],
  ['PowerPlatformSPN', new Set([
    'ALM4Dataverse.alm4dataverse-azdo-extensions.alm4dataverse-set-connection-variables.ALM4DataverseSetConnectionVariables@1',
    'microsoft-IsvExpTools.PowerPlatform-BuildTools.set-connection-variables.PowerPlatformSetConnectionVariables@2',
  ])],
]);

function findTaskForLine(lines, lineNumber) {
  // Diagnostics use zero-based lines. Only a less-indented preceding task can
  // own the input property; an allowlisted input alone is not an exemption.
  const propertyIndent = (lines[lineNumber].match(/^\s*/) || [''])[0].length;
  for (let index = lineNumber; index >= 0; index -= 1) {
    const match = lines[index].match(/^\s*-\s*task:\s*['"]?([^\s'"]+)['"]?\s*$/);
    if (match && (lines[index].match(/^\s*/) || [''])[0].length < propertyIndent) {
      return match[1];
    }
  }
  return null;
}

function isKnownExtensionDiagnostic(diagnostic, lines) {
  // Suppress only the known schema gap for the owning Marketplace task, leaving
  // unrelated diagnostics (including errors on other tasks) visible.
  const lineNumber = diagnostic.range.start.line;
  const line = lines[lineNumber] || '';
  const taskMatch = line.match(/^\s*-\s*task:\s*['"]?([^\s'"]+)['"]?\s*$/);
  if (
    taskMatch &&
    customTasks.has(taskMatch[1]) &&
    /^(String does not match the pattern|Value is not accepted)\b/.test(diagnostic.message)
  ) {
    return true;
  }

  const inputMatch = diagnostic.message.match(/^Unexpected property (\S+)$/);
  const owningTasks = inputMatch && customTaskInputs.get(inputMatch[1]);
  return Boolean(owningTasks && owningTasks.has(findTaskForLine(lines, lineNumber)));
}

async function main() {
  const errors = [];
  for (const file of [...files].sort()) {
    const content = fs.readFileSync(file, 'utf8');
    const document = parse(content);
    const fileLabel = path.relative(process.cwd(), file).split(path.sep).join('/');

    if (document.documents.length !== 1) {
      errors.push(`${fileLabel}: expected one YAML document, found ${document.documents.length}`);
      continue;
    }

    // Adapt the source to the language service without normalizing line endings:
    // offsets and reported positions must refer to the exact file being checked.
    const textDocument = {
      uri: require('node:url').pathToFileURL(file).href,
      languageId: 'azure-pipelines',
      version: 1,
      getText: () => content,
      positionAt: (offset) => {
        const lines = content.slice(0, offset).split(/\r?\n/);
        return { line: lines.length - 1, character: lines.at(-1).length };
      },
    };
    const diagnostics = await languageService.doValidation(textDocument, document);
    const lines = content.split(/\r?\n/);
    for (const diagnostic of diagnostics) {
      if (
        diagnostic.severity > DiagnosticSeverity.Warning ||
        isKnownExtensionDiagnostic(diagnostic, lines)
      ) {
        continue;
      }
      const severity = diagnostic.severity === DiagnosticSeverity.Error ? 'error' : 'warning';
      errors.push(
        `${fileLabel}:${diagnostic.range.start.line + 1}: ${severity}: ${diagnostic.message}`
      );
    }
  }

  for (const error of errors) {
    console.error(error);
  }

  if (errors.length > 0) {
    process.exitCode = 1;
  } else {
    console.log(`Validated ${files.size} Azure Pipelines YAML file(s) against Microsoft's schema.`);
  }
}

main().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
