/*
    html/tests/tablet-dom-stub.js

    A minimal, hand-rolled DOM stand-in for html/tablet.js -- same
    zero-dependency posture and same "trap innerHTML, never implement a
    real DOM/CSS engine" philosophy as html/tests/dom-stub.js (the HUD's
    own stub), but with a wider surface: unlike app.js's static markup
    (fixed rows already in index.html, only their fill/text/class ever
    change), tablet.js builds its ENTIRE visible screen from scratch on
    every render() call via document.createElement/appendChild/removeChild,
    so this stub additionally needs a real (if tiny) parent/child tree,
    per-element event listeners, and a `value` property for inputs.

    Deliberately a SEPARATE file from dom-stub.js, not an extension of it --
    html/app.js and its existing tests are never touched by this pass, and
    keeping this stub self-contained means there is zero risk of a change
    here ever affecting the HUD's own passing suite.
*/
'use strict';

function makeClassList(initial) {
    var set = new Set();
    if (initial) {
        String(initial).split(/\s+/).filter(Boolean).forEach(function (c) { set.add(c); });
    }
    return {
        add: function (c) { set.add(c); },
        remove: function (c) { set.delete(c); },
        toggle: function (c, force) {
            if (force === undefined) {
                if (set.has(c)) { set.delete(c); return false; }
                set.add(c);
                return true;
            }
            if (force) { set.add(c); return true; }
            set.delete(c);
            return false;
        },
        contains: function (c) { return set.has(c); },
        toArray: function () { return Array.from(set); },
    };
}

var ELEMENT_ID_SEQ = { n: 0 };

class Element {
    constructor(tagName, attrs) {
        this.tagName = String(tagName || 'div').toLowerCase();
        this._id = ++ELEMENT_ID_SEQ.n;
        this._attrs = Object.assign({}, attrs);
        this.classList = makeClassList(this._attrs.class);
        this.style = {};
        this.value = '';
        this._textContent = '';
        this._innerHTMLWrites = [];
        this._children = [];
        this.parentNode = null;
        this._listeners = {};
    }

    setAttribute(name, value) { this._attrs[name] = String(value); }
    getAttribute(name) { return Object.prototype.hasOwnProperty.call(this._attrs, name) ? this._attrs[name] : null; }
    removeAttribute(name) { delete this._attrs[name]; }
    hasAttribute(name) { return Object.prototype.hasOwnProperty.call(this._attrs, name); }

    get id() { return this._attrs.id || ''; }
    get innerHTMLWriteCount() { return this._innerHTMLWrites.length; }
    get classListArray() { return this.classList.toArray(); }

    appendChild(child) {
        child.parentNode = this;
        this._children.push(child);
        return child;
    }

    removeChild(child) {
        var idx = this._children.indexOf(child);
        if (idx !== -1) this._children.splice(idx, 1);
        child.parentNode = null;
        return child;
    }

    get firstChild() { return this._children.length > 0 ? this._children[0] : null; }
    get children() { return this._children.slice(); }
    get childNodes() { return this._children.slice(); }

    addEventListener(type, fn) {
        (this._listeners[type] = this._listeners[type] || []).push(fn);
    }

    removeEventListener(type, fn) {
        var list = this._listeners[type];
        if (!list) return;
        var idx = list.indexOf(fn);
        if (idx !== -1) list.splice(idx, 1);
    }

    /** Test-only: fires every listener registered for `type` on THIS
     * element (not a real bubbling implementation -- nothing in tablet.js
     * relies on event bubbling). */
    _dispatch(type, evtExtra) {
        var evt = Object.assign({ target: this, preventDefault: function () {} }, evtExtra || {});
        var list = (this._listeners[type] || []).slice();
        for (var i = 0; i < list.length; i++) list[i](evt);
    }

    /** Test-only convenience: simulates a real click. */
    click() { this._dispatch('click'); }

    /** Test-only convenience: sets `.value` then fires an `input` event,
     * exactly the sequence a real `<input>` produces when a user types. */
    typeValue(v) {
        this.value = v;
        this._dispatch('input', { target: this });
    }
}

Object.defineProperty(Element.prototype, 'textContent', {
    get() { return this._textContent; },
    set(v) { this._textContent = v === null || v === undefined ? '' : String(v); },
});

Object.defineProperty(Element.prototype, 'className', {
    get() { return this.classList.toArray().join(' '); },
    set(v) { this.classList = makeClassList(v); },
});

// Trapped, not simply unimplemented -- see dom-stub.js's identical rationale
// for the HUD: this is the harness's actual proof mechanism that tablet.js
// never writes innerHTML anywhere, not merely an assertion by reading source.
Object.defineProperty(Element.prototype, 'innerHTML', {
    get() { return this._innerHTMLWrites.length > 0 ? this._innerHTMLWrites[this._innerHTMLWrites.length - 1] : ''; },
    set(v) { this._innerHTMLWrites.push(v); },
});

class FakeDocument {
    constructor() {
        this._byId = new Map();
        this._all = [];
        this._listeners = {};
        this.readyState = 'complete';
    }

    createElement(tagName, attrs) {
        var el = new Element(tagName, attrs);
        this._all.push(el);
        if (el._attrs.id) this._byId.set(el._attrs.id, el);
        return el;
    }

    getElementById(id) {
        // Elements created before setAttribute('id', ...) was called after
        // the fact (tablet.js always sets id via the `attrs` constructor
        // argument, never via a later setAttribute call, but this stays
        // robust either way) -- fall back to a linear scan if the fast
        // path misses.
        if (this._byId.has(id)) return this._byId.get(id);
        for (var i = 0; i < this._all.length; i++) {
            if (this._all[i].getAttribute('id') === id) return this._all[i];
        }
        return null;
    }

    addEventListener(type, fn) {
        (this._listeners[type] = this._listeners[type] || []).push(fn);
    }

    removeEventListener(type, fn) {
        var list = this._listeners[type];
        if (!list) return;
        var idx = list.indexOf(fn);
        if (idx !== -1) list.splice(idx, 1);
    }

    _dispatch(type, evtExtra) {
        var evt = Object.assign({ preventDefault: function () {} }, evtExtra || {});
        var list = (this._listeners[type] || []).slice();
        for (var i = 0; i < list.length; i++) list[i](evt);
    }
}

/** Builds a FakeDocument with the one static element html/tablet.html
 * actually ships (`#k9tablet-root`) -- everything else is built by
 * tablet.js itself at runtime. */
function buildTabletDocument() {
    var doc = new FakeDocument();
    var root = doc.createElement('div', { id: 'k9tablet-root', class: 'k9tablet-root' });
    doc._byId.set('k9tablet-root', root);
    doc._all.push(root);
    return doc;
}

/** Depth-first walk of the whole live tree rooted at `node`, collecting
 * every node for which `predicate(node)` is truthy. Test-only DOM
 * inspection -- NOT a real querySelectorAll (no CSS selector parsing). */
function findAll(node, predicate) {
    var out = [];
    (function walk(n) {
        if (predicate(n)) out.push(n);
        for (var i = 0; i < n._children.length; i++) walk(n._children[i]);
    })(node);
    return out;
}

/** Convenience: every element under `node` whose tagName matches (case-insensitive). */
function findByTag(node, tag) {
    tag = String(tag).toLowerCase();
    return findAll(node, function (n) { return n.tagName === tag; });
}

/** Convenience: every element under `node` carrying `cls` in its classList. */
function findByClass(node, cls) {
    return findAll(node, function (n) { return n.classList && n.classList.contains(cls); });
}

/** Convenience: every element under `node` whose OWN textContent (not a
 * descendant's) equals `text` exactly -- mainly for locating a specific
 * button by its rendered label. */
function findByText(node, text) {
    return findAll(node, function (n) { return n._textContent === text; });
}

module.exports = { Element, FakeDocument, buildTabletDocument, findAll, findByTag, findByClass, findByText };
