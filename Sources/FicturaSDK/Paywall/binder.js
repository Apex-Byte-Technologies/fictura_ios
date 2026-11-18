// Copied verbatim from the React Native SDK: fictura_sdk src/paywall/binder.ts (BINDER).
// Keep the two in sync; contract tests compare them.
  window.__FICTURA__.bind = function () {
    try {
      var F = window.__FICTURA__ || {};
      var pkgs = F.packages || [];
      var slots = F.slots || {};
      var find = function (sel) {
        if (!sel) return null;
        if (slots[sel]) return slots[sel];
        for (var i = 0; i < pkgs.length; i++) if (pkgs[i].id === sel) return pkgs[i];
        for (var j = 0; j < pkgs.length; j++) if (pkgs[j].period === sel) return pkgs[j];
        return null;
      };
      /*
       * Assets. The design names a slot; the app config says which image goes
       * there, so a client can put their own photo on a shipped template without
       * the template being edited or the app being rebuilt.
       *
       * Both ways an image can appear are handled. An <img> gets its src set;
       * anything else is treated as a background, because most of these are
       * full-bleed scenes set in CSS rather than <img> tags, and a background
       * cannot be swapped by setting an attribute.
       *
       * A slot with no image configured is left exactly as the design shipped it.
       * That is the point: the artwork it came with is the default, not a blank.
       */
      /*
       * Copy. A design names a slot where its own words sit; the app config can
       * replace them. Only the text is touched, never the markup around it, so a
       * client rewriting a headline cannot break the layout it sits in.
       */
      var copy = F.copy || {};
      var texts = document.querySelectorAll('[data-fictura-text]');
      for (var t1 = 0; t1 < texts.length; t1++) {
        var tv = copy[texts[t1].getAttribute('data-fictura-text')];
        if (typeof tv === 'string' && tv.length) texts[t1].textContent = tv;
      }
      /*
       * Colours, applied as CSS custom properties on the root so one value can
       * reach every rule that uses it. A design opts in by drawing from var(--fx-*)
       * instead of a literal; one that does not is simply unaffected.
       */
      var colors = F.colors || {};
      for (var key in colors) {
        if (!Object.prototype.hasOwnProperty.call(colors, key)) continue;
        if (/^[a-z0-9_-]{1,32}$/i.test(key) && /^#[0-9a-f]{3,8}$/i.test(String(colors[key]))) {
          document.documentElement.style.setProperty('--fx-' + key, colors[key]);
        }
      }
      var assets = F.assets || {};
      var slotted = document.querySelectorAll('[data-fictura-asset]');
      for (var a1 = 0; a1 < slotted.length; a1++) {
        var el = slotted[a1];
        var url = assets[el.getAttribute('data-fictura-asset')];
        if (!url) continue;
        if (el.tagName === 'IMG') el.setAttribute('src', url);
        else el.style.backgroundImage = 'url("' + String(url).replace(/"/g, '%22') + '")';
      }
      /*
       * The same three bags again, for a design that marked nothing.
       *
       * Almost every design in use was written before marking existed, and
       * those are the ones clients actually have. Rather than require a design
       * to be edited before it can be edited, an override may be keyed by the
       * VALUE it replaces — the image URL the design draws, the colour it
       * paints, the words it shows — which the dashboard reads straight out of
       * the markup and offers as fields.
       *
       * The two schemes cannot collide, because a key's shape says which it is:
       * a mark name is a bare word, an image key begins with http, a colour key
       * begins with #. Copy is the one that could overlap, so the text pass only
       * runs on a design that marked no text at all — the same rule the
       * dashboard follows when it decides which fields to offer.
       *
       * Cost is the reason this is shaped the way it is. bind() runs on first
       * paint and again when packages land, on a phone, so:
       *   - a bag with nothing in it does no work at all, which is the case for
       *     every paywall nobody has customised — the usual one;
       *   - each node is written back ONCE with every change already in it,
       *     because a stylesheet re-assigned per override is a style
       *     recalculation per override;
       *   - the document is walked only when there is copy to apply.
       */
      var urlKeys = [], paints = [], hasCopy = false, q;
      for (q in assets) {
        if (!Object.prototype.hasOwnProperty.call(assets, q)) continue;
        if (q.slice(0, 4) === 'http' && assets[q]) urlKeys.push(q);
      }
      for (q in colors) {
        if (!Object.prototype.hasOwnProperty.call(colors, q)) continue;
        if (q.charAt(0) !== '#' || !/^#[0-9a-f]{3,8}$/i.test(String(colors[q]))) continue;
        /*
         * Both spellings of the one colour, since a design may use either and
         * the dashboard offers them as a single field. The trailing guard is
         * what stops #fff from eating the first half of #ffffff.
         */
        var forms = q;
        if (q.length === 7 && q.charAt(1) === q.charAt(2) && q.charAt(3) === q.charAt(4) && q.charAt(5) === q.charAt(6)) {
          forms = q + '|#' + q.charAt(1) + q.charAt(3) + q.charAt(5);
        }
        paints.push([new RegExp('(?:' + forms + ')(?![0-9a-fA-F])', 'gi'), String(colors[q])]);
      }
      for (q in copy) {
        if (Object.prototype.hasOwnProperty.call(copy, q)) { hasCopy = true; break; }
      }

      if (urlKeys.length || paints.length) {
        var restyle = function (text) {
          var out = text, z;
          for (z = 0; z < urlKeys.length; z++) {
            var from = urlKeys[z], to = String(assets[from]);
            if (out.indexOf(from) !== -1) out = out.split(from).join(to);
            /*
             * A URL written with &amp; in the source keeps that spelling inside
             * a <style> block, because the parser treats stylesheet text as raw.
             */
            var encoded = from.split('&').join('&amp;');
            if (encoded !== from && out.indexOf(encoded) !== -1) out = out.split(encoded).join(to);
          }
          for (z = 0; z < paints.length; z++) out = out.replace(paints[z][0], paints[z][1]);
          return out;
        };
        var sheets = document.getElementsByTagName('style');
        for (var y1 = 0; y1 < sheets.length; y1++) {
          var was = sheets[y1].textContent, now = restyle(was);
          if (now !== was) sheets[y1].textContent = now;
        }
        var styled = document.querySelectorAll('[style]');
        for (var y2 = 0; y2 < styled.length; y2++) {
          var had = styled[y2].getAttribute('style') || '', next = restyle(had);
          if (next !== had) styled[y2].setAttribute('style', next);
        }
        if (urlKeys.length) {
          var pics = document.getElementsByTagName('img');
          for (var y3 = 0; y3 < pics.length; y3++) {
            var swap = assets[pics[y3].getAttribute('src')];
            if (swap) pics[y3].setAttribute('src', String(swap));
          }
        }
      }

      if (hasCopy && texts.length === 0 && document.body && typeof document.createTreeWalker === 'function') {
        var walker = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT, null, false);
        var found = [];
        for (var tn = walker.nextNode(); tn; tn = walker.nextNode()) found.push(tn);
        for (var f1 = 0; f1 < found.length; f1++) {
          var node = found[f1];
          var parent = node.parentNode;
          if (!parent || parent.nodeType !== 1) continue;
          if (parent.tagName === 'SCRIPT' || parent.tagName === 'STYLE') continue;
          /*
           * What the renderer wrote is not the design's copy. A price bound a
           * moment ago must not be replaced by the words that stood there when
           * the dashboard read the markup.
           */
          if (parent.getAttribute('data-fictura-price') !== null) continue;
          if (parent.getAttribute('data-fictura-plan') !== null) continue;
          /*
           * Markup is indented and wrapped for whoever writes it, and the text
           * node keeps every bit of that. Collapsing here and in the dashboard
           * means a headline split over three source lines is still one key.
           */
          var said = node.nodeValue.replace(/\s+/g, ' ').trim();
          if (!said) continue;
          var instead = copy[said];
          if (typeof instead === 'string' && instead.length) node.nodeValue = instead;
        }
      }
      /*
       * Legal links. The design says which one; the host's config says where it
       * goes. A link with no address is HIDDEN rather than left dead — a Terms
       * link that does nothing reads as broken to a reviewer, and is.
       */
      var legal = F.legal || {};
      var links = document.querySelectorAll('[data-fictura-legal]');
      for (var l = 0; l < links.length; l++) {
        var a = links[l];
        var which = a.getAttribute('data-fictura-legal');
        // An explicit href on the element wins: a design may point one paywall
        // at a different page without changing the app.
        var href = a.getAttribute('data-fictura-href') || legal[which === 'privacy' ? 'privacyUrl' : 'termsUrl'];
        if (href) { a.setAttribute('href', href); a.style.removeProperty('display'); }
        else { a.style.display = 'none'; }
        // Still reported, as it always was. Binding runs again on every update,
        // so the listener is attached once and marked.
        if (a.getAttribute('data-fictura-bound') !== '1') {
          a.setAttribute('data-fictura-bound', '1');
          (function (w) {
            a.addEventListener('click', function () {
              try { F.track(w === 'privacy' ? 'privacy_tapped' : 'terms_tapped'); } catch (e) {}
            });
          })(which);
        }
      }

      var nodes = document.querySelectorAll('[data-fictura-plan]');
      for (var n = 0; n < nodes.length; n++) {
        (function (btn) {
          var pkg = find(btn.getAttribute('data-fictura-plan'));
          if (!pkg) {
            // No such plan for this app / this store. Hiding beats a dead button.
            btn.style.display = 'none';
            return;
          }
          btn.style.removeProperty('display');
          var price = btn.querySelector('[data-fictura-price]');
          if (price) price.textContent = pkg.price_string;
          var period = btn.querySelector('[data-fictura-period]');
          if (period) period.textContent = pkg.period;
          var trial = btn.querySelector('[data-fictura-trial]');
          if (trial) trial.textContent = pkg.trial_days == null ? '' : String(pkg.trial_days);
          if (btn.getAttribute('data-fictura-bound') === '1') return;
          btn.setAttribute('data-fictura-bound', '1');
          btn.addEventListener('click', function () {
            // A design may mark a plan unbuyable — a trial this user has
            // already used, shown greyed rather than hidden. The binder owns
            // the tap, so it is the only place that can honour that.
            if (btn.getAttribute('aria-disabled') === 'true') return;
            var live = find(btn.getAttribute('data-fictura-plan'));
            if (live) F.purchase(live.id);
          });
        })(nodes[n]);
      }
    } catch (e) {}
  };
  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', function () { window.__FICTURA__.bind(); });
  } else {
    window.__FICTURA__.bind();
  }
  window.addEventListener('fictura:packages', function () { window.__FICTURA__.bind(); });
