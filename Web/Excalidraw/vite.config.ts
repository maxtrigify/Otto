import { defineConfig } from 'vite'
import react from '@vitejs/plugin-react'
import { cpSync } from 'node:fs'
import { dirname, resolve } from 'node:path'
import { fileURLToPath } from 'node:url'

const projectDirectory = dirname(fileURLToPath(import.meta.url))

const copyExcalidrawFonts = () => {
  let outputDirectory = ''
  return {
    name: 'copy-excalidraw-fonts',
    configResolved(config: { build: { outDir: string } }) {
      outputDirectory = config.build.outDir
    },
    closeBundle() {
      cpSync(
        resolve(projectDirectory, 'node_modules/@excalidraw/excalidraw/dist/prod/fonts'),
        resolve(outputDirectory, 'assets/fonts'),
        { recursive: true },
      )
    },
  }
}

export default defineConfig({
  base: './',
  plugins: [react(), copyExcalidrawFonts()],
  build: {
    outDir: '../../Sources/OttoApp/Resources/Excalidraw',
    emptyOutDir: true,
  },
})
