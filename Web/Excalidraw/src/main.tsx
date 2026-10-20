import React, { useCallback, useEffect, useRef } from 'react'
import { createRoot } from 'react-dom/client'
import {
  CaptureUpdateAction,
  Excalidraw,
  convertToExcalidrawElements,
  serializeAsJSON,
} from '@excalidraw/excalidraw'
import type {
  AppState,
  BinaryFiles,
  ExcalidrawImperativeAPI,
} from '@excalidraw/excalidraw/types'
import type { ExcalidrawElement } from '@excalidraw/excalidraw/element/types'
import type { ExcalidrawElementSkeleton } from '@excalidraw/excalidraw/data/transform'
import '@excalidraw/excalidraw/index.css'
import './muse.css'

type OttoShape = {
  id: string
  type: 'rectangle' | 'ellipse' | 'diamond' | 'text' | 'note' | 'arrow'
  x: number
  y: number
  width?: number
  height?: number
  text?: string
  color?: string
}

type OttoAction =
  | { id: string; kind: 'createShapes'; shapes: OttoShape[] }
  | { id: string; kind: 'deleteShapes'; shapeIDs: string[] }
  | { id: string; kind: 'clear' }
  | { id: string; kind: 'fit' }

type SavedScene = {
  type?: string
  elements?: readonly ExcalidrawElement[]
  appState?: Partial<AppState>
  files?: BinaryFiles
}

declare global {
  interface Window {
    webkit?: {
      messageHandlers?: {
        museWhiteboard?: { postMessage: (message: unknown) => void }
      }
    }
    museWhiteboard?: {
      loadDocumentBase64: (encoded: string | null) => void
      applyActionsBase64: (encoded: string) => void
    }
  }
}

const colorMap: Record<string, string> = {
  black: '#1b1b1f',
  blue: '#4c6ef5',
  green: '#2f9e44',
  grey: '#868e96',
  'light-blue': '#a5d8ff',
  'light-green': '#b2f2bb',
  'light-red': '#ffc9c9',
  'light-violet': '#d0bfff',
  orange: '#f08c00',
  red: '#e03131',
  violet: '#7950f2',
  white: '#f8f9fa',
  yellow: '#ffd43b',
}

const postToOtto = (message: unknown) => {
  window.webkit?.messageHandlers?.museWhiteboard?.postMessage(message)
}

const decodeBase64 = (encoded: string) =>
  decodeURIComponent(
    Array.from(atob(encoded), (character) =>
      `%${character.charCodeAt(0).toString(16).padStart(2, '0')}`,
    ).join(''),
  )

const colorFor = (color?: string) => colorMap[color ?? 'black'] ?? colorMap.black

const skeletonForShape = (shape: OttoShape): ExcalidrawElementSkeleton => {
  const strokeColor = colorFor(shape.color)
  const common = {
    id: shape.id,
    x: shape.x,
    y: shape.y,
    strokeColor,
    roughness: 1 as const,
  }

  if (shape.type === 'text') {
    return {
      ...common,
      type: 'text',
      text: shape.text ?? '',
      fontSize: 22,
      fontFamily: 5,
    }
  }

  if (shape.type === 'arrow') {
    return {
      ...common,
      type: 'arrow',
      points: [
        [0, 0],
        [shape.width ?? 180, shape.height ?? 0],
      ],
      endArrowhead: 'arrow',
      label: shape.text ? { text: shape.text, fontFamily: 5 } : undefined,
    }
  }

  if (shape.type === 'note') {
    return {
      ...common,
      type: 'rectangle',
      width: shape.width ?? 200,
      height: shape.height ?? 140,
      backgroundColor: colorFor(shape.color ?? 'yellow'),
      fillStyle: 'solid',
      roundness: { type: 3 },
      label: shape.text ? { text: shape.text, fontFamily: 5 } : undefined,
    }
  }

  return {
    ...common,
    type: shape.type,
    width: shape.width ?? 180,
    height: shape.height ?? 110,
    backgroundColor: 'transparent',
    fillStyle: 'hachure',
    label: shape.text ? { text: shape.text, fontFamily: 5 } : undefined,
  }
}

function Whiteboard() {
  const apiRef = useRef<ExcalidrawImperativeAPI | null>(null)
  const saveTimer = useRef<number | undefined>(undefined)
  const loadingDocument = useRef(false)

  const save = useCallback((appliedActionIDs: string[] = []) => {
    const api = apiRef.current
    if (!api || loadingDocument.current) return
    window.clearTimeout(saveTimer.current)
    saveTimer.current = window.setTimeout(() => {
      const document = serializeAsJSON(
        api.getSceneElementsIncludingDeleted(),
        api.getAppState(),
        api.getFiles(),
        'local',
      )
      postToOtto({ type: 'change', document, appliedActionIDs })
    }, appliedActionIDs.length > 0 ? 0 : 350)
  }, [])

  const loadDocument = useCallback((encoded: string | null) => {
    const api = apiRef.current
    if (!api || !encoded) return
    try {
      const scene = JSON.parse(decodeBase64(encoded)) as SavedScene
      // Legacy whiteboard snapshots have a different structure. Leave the new
      // Excalidraw board empty instead of corrupting or crashing the node.
      if (scene.type !== 'excalidraw' || !Array.isArray(scene.elements)) return
      loadingDocument.current = true
      if (scene.files) api.addFiles(Object.values(scene.files))
      api.updateScene({
        elements: scene.elements,
        appState: { ...scene.appState, theme: 'dark' },
        captureUpdate: CaptureUpdateAction.NEVER,
      })
      api.history.clear()
    } catch (error) {
      postToOtto({
        type: 'error',
        message: error instanceof Error ? error.message : 'The whiteboard document is invalid.',
      })
    } finally {
      window.setTimeout(() => {
        loadingDocument.current = false
      }, 0)
    }
  }, [])

  const applyActions = useCallback(
    (actions: OttoAction[]) => {
      const api = apiRef.current
      if (!api || actions.length === 0) return
      const appliedActionIDs: string[] = []

      for (const action of actions) {
        switch (action.kind) {
          case 'createShapes': {
            const createdIDs = new Set(action.shapes.map((shape) => shape.id))
            const retained = api.getSceneElements().filter((element) => {
              const containerID = 'containerId' in element ? element.containerId : null
              return !createdIDs.has(element.id) && (!containerID || !createdIDs.has(containerID))
            })
            const created = convertToExcalidrawElements(
              action.shapes.map(skeletonForShape),
              { regenerateIds: false },
            )
            api.updateScene({
              elements: [...retained, ...created],
              captureUpdate: CaptureUpdateAction.IMMEDIATELY,
            })
            break
          }
          case 'deleteShapes': {
            const deletedIDs = new Set(action.shapeIDs)
            const elements = api.getSceneElements().filter((element) => {
              const containerID = 'containerId' in element ? element.containerId : null
              return !deletedIDs.has(element.id) && (!containerID || !deletedIDs.has(containerID))
            })
            api.updateScene({ elements, captureUpdate: CaptureUpdateAction.IMMEDIATELY })
            break
          }
          case 'clear':
            api.updateScene({ elements: [], captureUpdate: CaptureUpdateAction.IMMEDIATELY })
            break
          case 'fit': {
            const elements = api.getSceneElements()
            if (elements.length > 0) {
              api.scrollToContent(elements, { fitToViewport: true, animate: true })
            }
            break
          }
        }
        appliedActionIDs.push(action.id)
      }

      window.requestAnimationFrame(() => save(appliedActionIDs))
    },
    [save],
  )

  const handleAPI = useCallback(
    (api: ExcalidrawImperativeAPI) => {
      apiRef.current = api
      window.museWhiteboard = {
        loadDocumentBase64: loadDocument,
        applyActionsBase64(encoded) {
          try {
            applyActions(JSON.parse(decodeBase64(encoded)))
          } catch (error) {
            postToOtto({
              type: 'error',
              message: error instanceof Error ? error.message : 'The agent action is invalid.',
            })
          }
        },
      }
      postToOtto({ type: 'ready' })
    },
    [applyActions, loadDocument],
  )

  useEffect(
    () => () => {
      window.clearTimeout(saveTimer.current)
      delete window.museWhiteboard
      apiRef.current = null
    },
    [],
  )

  return (
    <div className="muse-whiteboard">
      <Excalidraw
        excalidrawAPI={handleAPI}
        onChange={() => save()}
        theme="dark"
        name="Otto Whiteboard"
        autoFocus={false}
        detectScroll={false}
        handleKeyboardGlobally={false}
      />
    </div>
  )
}

createRoot(document.getElementById('root')!).render(
  <React.StrictMode>
    <Whiteboard />
  </React.StrictMode>,
)
