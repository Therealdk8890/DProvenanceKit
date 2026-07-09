import { expect, test } from '@playwright/test'
import fs from 'node:fs'
import os from 'node:os'
import path from 'node:path'

const fallbackExport = {
  summary: {
    runs: '2',
    regressionRisk: 'High',
    changedLogicPaths: 1,
    structuralFingerprint: 'smoke',
  },
  metrics: {
    driftScore: 40,
    addedNodes: 0,
    removedNodes: 1,
    changedPaths: 1,
    risk: 'High',
  },
  timeline: {
    runA: { label: 'Baseline', date: 'Jan 1, 12:00' },
    runB: { label: 'Candidate', date: 'Jan 1, 12:05' },
  },
  tree: {
    id: 'root',
    label: 'Coding Agent Regression',
    type: 'changed',
    children: [
      { id: 'node-1', label: 'fileIO', type: 'unchanged' },
      { id: 'node-2', label: 'tool', type: 'removed' },
    ],
  },
}

function exportPath() {
  if (process.env.DPK_WEB_EXPORT_JSON) {
    return process.env.DPK_WEB_EXPORT_JSON
  }

  const file = path.join(os.tmpdir(), 'dpk-webvisualizer-smoke.json')
  fs.writeFileSync(file, JSON.stringify(fallbackExport, null, 2))
  return file
}

test('loads a WebDiffExport JSON artifact through the browser uploader', async ({ page }) => {
  await page.goto('/')
  await expect(page.getByText('Reasoning Engine')).toBeVisible()

  const fileChooser = page.waitForEvent('filechooser')
  await page.getByRole('button', { name: 'Load JSON' }).click()
  await (await fileChooser).setFiles(exportPath())

  await expect(page.getByText('Coding Agent Regression')).toBeVisible()
  await expect(page.getByText('fileIO')).toBeVisible()
  await expect(page.getByText('High')).toBeVisible()
})
