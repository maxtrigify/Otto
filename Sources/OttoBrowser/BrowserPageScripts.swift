import Foundation

// The page scripts every Otto browser renderer runs, so a bot reads and acts on pages the same
// way in the Mac app's WebKit views and in Otto Desktop's Chromium views (via otto-engine).

public struct BrowserDOMSnapshot: Codable, Sendable {
  public var url: String
  public var title: String?
  public var revision: String
  public var elements: [BrowserPageElement]
}

public struct BrowserDOMInteractionResult: Codable, Sendable {
  public var ok: Bool
  public var error: String?
  public var url: String
  public var message: String?
}

public struct BrowserDOMLocateResult: Codable, Sendable {
  public var ok: Bool
  public var error: String?
  public var url: String
  public var x: Double?
  public var y: Double?
  public var hit: Bool?

  public func throwIfFailed(nodeID: UUID, elementID: String?) throws {
    guard !ok else { return }
    switch error {
    case "stale": throw BrowserRuntimeError.stalePageSnapshot
    case "missing": throw BrowserRuntimeError.pageElementNotFound(elementID ?? "unknown")
    default: throw BrowserRuntimeError.pageInteractionUnavailable(nodeID)
    }
  }
}

/// Scripts evaluated in the page; each returns a JSON string the matching result type decodes.
public enum BrowserPageScripts {
  /// Scrolls the target into view and reports its centre in page (CSS) coordinates, plus
  /// whether a real click there would land on it rather than on an overlay.
  public static func locate(_ requestJSON: String) -> String {
    """
    (() => {
      const request = \(requestJSON);
      const page = window.__ottoAgentPage;
      const result = (value) => JSON.stringify({url: location.href, ...value});
      if (!page || page.revision !== request.revision) {
        return result({ok: false, error: 'stale'});
      }
      const element = page.elements.get(request.elementID);
      if (!element || !element.isConnected) return result({ok: false, error: 'missing'});
      element.scrollIntoView({block: 'center', inline: 'center', behavior: 'instant'});
      const rect = element.getBoundingClientRect();
      const x = rect.left + rect.width / 2;
      const y = rect.top + rect.height / 2;
      let top = document.elementFromPoint(x, y);
      while (top && top.shadowRoot) {
        const inner = top.shadowRoot.elementFromPoint(x, y);
        if (!inner || inner === top) break;
        top = inner;
      }
      let hit = false;
      for (let node = top; node; node = node.parentNode || node.host) {
        if (node === element) { hit = true; break; }
      }
      const inside = x >= 0 && y >= 0 && x <= innerWidth && y <= innerHeight;
      return result({ok: true, x, y, hit: hit && inside});
    })()
    """
  }

  public static var inspection: String {
    #"""
    (() => {
      const selector = [
        'a[href]', 'button', 'input', 'textarea', 'select', 'summary',
        '[role="button"]', '[role="link"]', '[role="checkbox"]', '[role="menuitem"]',
        '[contenteditable="true"]', '[tabindex]'
      ].join(',');
      const roots = [document];
      for (let index = 0; index < roots.length; index += 1) {
        for (const element of roots[index].querySelectorAll('*')) {
          if (element.shadowRoot) roots.push(element.shadowRoot);
        }
      }
      const candidates = roots.flatMap(root => Array.from(root.querySelectorAll(selector)));
      const elements = new Map();
      const revision = (globalThis.crypto && crypto.randomUUID)
        ? crypto.randomUUID()
        : `${Date.now()}-${Math.random()}`;
      let nextID = 0;
      const output = [];
      for (const element of candidates) {
        const rect = element.getBoundingClientRect();
        const style = getComputedStyle(element);
        if (rect.width <= 0 || rect.height <= 0 || style.visibility === 'hidden' ||
            style.display === 'none') continue;
        const tag = element.tagName.toLowerCase();
        const inputType = tag === 'input' ? (element.type || 'text').toLowerCase() : '';
        const role = element.getAttribute('role') ||
          (tag === 'a' ? 'link' : tag === 'button' || tag === 'summary' ? 'button' :
           tag === 'select' ? 'combobox' : inputType === 'checkbox' ? 'checkbox' :
           tag === 'input' || tag === 'textarea' || element.isContentEditable ? 'textbox' : tag);
        const label = element.getAttribute('aria-label') ||
          (element.labels && element.labels[0] && element.labels[0].innerText) ||
          element.alt || element.title || element.innerText || element.placeholder || '';
        const id = `e${++nextID}`;
        elements.set(id, element);
        const nonTextInputTypes = new Set([
          'button', 'checkbox', 'color', 'file', 'hidden', 'image', 'radio', 'range', 'reset',
          'submit'
        ]);
        const canType = tag === 'textarea' || element.isContentEditable ||
          (tag === 'input' && !nonTextInputTypes.has(inputType));
        const actions = canType ? ['type'] : tag === 'select' ? ['select'] : ['click'];
        output.push({
          id,
          role,
          name: String(label).trim().replace(/\s+/g, ' ').slice(0, 240),
          placeholder: element.placeholder || null,
          bounds: {x: rect.x, y: rect.y, width: rect.width, height: rect.height},
          actions,
          isDisabled: Boolean(element.disabled || element.getAttribute('aria-disabled') === 'true'),
          isSensitive: inputType === 'password',
          isInViewport: rect.bottom >= 0 && rect.right >= 0 &&
            rect.top <= innerHeight && rect.left <= innerWidth
        });
      }
      window.__ottoAgentPage = {revision, elements};
      // Off-screen elements stay addressable (interactions scroll them into view), but the
      // visible ones lead so a truncated list still covers what the user is looking at.
      output.sort((left, right) => Number(right.isInViewport) - Number(left.isInViewport));
      return JSON.stringify({
        url: location.href,
        title: document.title || null,
        revision,
        elements: output.slice(0, 1_000).map(({isInViewport, ...element}) => element)
      });
    })()
    """#
  }

  public static func interaction(_ requestJSON: String) -> String {
    """
    (() => {
      const request = \(requestJSON);
      const page = window.__ottoAgentPage;
      const result = (value) => JSON.stringify({url: location.href, ...value});
      if (!page || page.revision !== request.revision) {
        return result({ok: false, error: 'stale'});
      }
      if (request.kind === 'scroll') {
        window.scrollBy({left: request.deltaX || 0, top: request.deltaY || 0, behavior: 'instant'});
        return result({ok: true, message: 'Scrolled page'});
      }
      const element = page.elements.get(request.elementID);
      if (!element || !element.isConnected) return result({ok: false, error: 'missing'});
      element.scrollIntoView({block: 'center', inline: 'center'});
      if (request.kind === 'click') {
        // Many apps (X, LinkedIn, Radix/Headless UI menus) act on pointerdown or mousedown and
        // ignore a bare element.click(), so replay the full pointer sequence at the centre.
        const rect = element.getBoundingClientRect();
        const point = {
          bubbles: true, cancelable: true, composed: true, view: window, button: 0,
          clientX: rect.left + rect.width / 2, clientY: rect.top + rect.height / 2
        };
        const pointer = {...point, pointerId: 1, pointerType: 'mouse', isPrimary: true};
        element.dispatchEvent(new PointerEvent('pointerover', pointer));
        element.dispatchEvent(new MouseEvent('mouseover', point));
        element.dispatchEvent(new PointerEvent('pointerdown', {...pointer, buttons: 1}));
        element.dispatchEvent(new MouseEvent('mousedown', {...point, buttons: 1}));
        element.focus({preventScroll: true});
        element.dispatchEvent(new PointerEvent('pointerup', pointer));
        element.dispatchEvent(new MouseEvent('mouseup', point));
        element.click();
        return result({ok: true, message: 'Clicked element'});
      }
      if (request.kind === 'type') {
        element.focus();
        if (element.isContentEditable) {
          // Rich editors (Draft.js on X, Lexical, ProseMirror, Quill) keep their own document
          // model. Assigning textContent rewrites the DOM behind their back, so the text
          // vanishes on the next render and Post/Send stays disabled. Select the existing
          // content and insert through the editing pipeline, which fires beforeinput/input
          // events those editors handle exactly like real typing.
          const selection = window.getSelection();
          const range = document.createRange();
          range.selectNodeContents(element);
          selection.removeAllRanges();
          selection.addRange(range);
          const text = request.text || '';
          if ((element.innerText || '').trim()) document.execCommand('delete', false);
          const inserted = text ? document.execCommand('insertText', false, text) : true;
          // Only plain contenteditable regions without an editing pipeline reach this fallback;
          // overwriting a model-backed editor here would desynchronise it again.
          if (!inserted) {
            element.textContent = text;
            element.dispatchEvent(new InputEvent('input', {
              bubbles: true, inputType: 'insertText', data: text
            }));
          }
          return result({ok: true, message: 'Entered text'});
        } else {
          // Use the native property setter so React and other controlled-input frameworks see
          // the change instead of immediately restoring their stale state.
          const prototype = element.tagName.toLowerCase() === 'textarea'
            ? HTMLTextAreaElement.prototype : HTMLInputElement.prototype;
          const setter = Object.getOwnPropertyDescriptor(prototype, 'value')?.set;
          if (setter) setter.call(element, request.text || '');
          else element.value = request.text || '';
        }
        element.dispatchEvent(new InputEvent('input', {
          bubbles: true, inputType: 'insertText', data: request.text || ''
        }));
        element.dispatchEvent(new Event('change', {bubbles: true}));
        return result({ok: true, message: 'Entered text'});
      }
      return result({ok: false, error: 'unsupported'});
    })()
    """
  }

  public static func assessment(_ requestJSON: String) -> String {
    """
    (() => {
      const request = \(requestJSON);
      const page = window.__ottoAgentPage;
      if (!page || page.revision !== request.revision) {
        return JSON.stringify({requiresConfirmation: false, reason: null});
      }
      const element = page.elements.get(request.elementID);
      if (!element || !element.isConnected) {
        return JSON.stringify({requiresConfirmation: false, reason: null});
      }
      const tag = element.tagName.toLowerCase();
      const type = String(element.type || '').toLowerCase();
      const label = String(
        element.getAttribute('aria-label') || element.innerText || element.title || element.value || ''
      ).trim().split(' ').filter(Boolean).join(' ').slice(0, 120);
      const href = String(element.getAttribute('href') || '').toLowerCase();
      const normalizedLabel = label.toLowerCase().replace(/[^a-z0-9]+/g, ' ');
      const labelWords = new Set(normalizedLabel.split(' ').filter(Boolean));
      const commits = [
        'send', 'submit', 'publish', 'post', 'delete', 'remove', 'purchase', 'buy', 'pay',
        'order', 'book', 'reserve', 'transfer', 'connect', 'follow', 'unfollow', 'like',
        'accept', 'decline', 'confirm', 'signout'
      ].some(word => labelWords.has(word));
      const submitsForm =
        (tag === 'input' && ['submit', 'image'].includes(type)) ||
        (tag === 'button' && element.closest('form') && (!type || type === 'submit'));
      const externalProtocol = href.startsWith('mailto:') || href.startsWith('tel:');
      const requiresConfirmation = Boolean(
        submitsForm || externalProtocol || element.hasAttribute('download') || commits
      );
      return JSON.stringify({
        requiresConfirmation,
        reason: requiresConfirmation ? `This may perform “${label || 'a consequential action'}”` : null
      });
    })()
    """
  }
}
