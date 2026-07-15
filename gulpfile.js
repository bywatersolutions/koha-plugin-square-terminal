const { dest, series, src } = require('gulp');
const { exec } = require('child_process');
const util = require('util');
const execPromise = util.promisify(exec);

const fs = require('fs');
const path = require('path');

const today = new Date().toISOString().split('T')[0]; // Format: YYYY-MM-DD

const package_json = JSON.parse(fs.readFileSync('./package.json'));
const release_filename = `${package_json.name}-v${package_json.version}.kpz`;

const pm_name = 'SquareTerminal';
const pm_file = pm_name + '.pm';
const pm_file_path = path.join('Koha', 'Plugin', 'Com', 'ByWaterSolutions');
const pm_file_path_full = path.join(pm_file_path, pm_file);
const pm_file_path_dist = path.join('dist', pm_file_path);
const pm_file_path_full_dist = path.join(pm_file_path_dist, pm_file);
const pm_bundle_path = path.join(pm_file_path, pm_name);

console.log(release_filename);
console.log(pm_file_path_full_dist);

async function build() {
  await execPromise('mkdir -p dist');
  await execPromise('cp -r Koha dist/.');
  await execPromise(`sed -i -e "s/1970-01-01/${today}/g" ${pm_file_path_full_dist}`);
  await execPromise(`cd dist && zip -r ../${release_filename} ./Koha`);
  await execPromise('rm -rf dist');
}

exports.build = build;
