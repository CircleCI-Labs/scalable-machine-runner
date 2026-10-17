// Hamburger menu for mobile navigation (Hextra, with a null-safe sidebar container for 404).

document.addEventListener('DOMContentLoaded', function () {
  const menu = document.querySelector('.hextra-hamburger-menu');
  const sidebarContainer = document.querySelector('.hextra-sidebar-container');
  if (!menu || !sidebarContainer) {
    return;
  }

  const mobileQuery = window.matchMedia('(max-width: 767px)');

  function isMenuOpen() {
    return menu.querySelector('svg').classList.contains('open');
  }

  function syncAriaHidden() {
    if (mobileQuery.matches) {
      sidebarContainer.setAttribute('aria-hidden', isMenuOpen() ? 'false' : 'true');
    } else {
      sidebarContainer.removeAttribute('aria-hidden');
    }
  }

  syncAriaHidden();
  mobileQuery.addEventListener('change', syncAriaHidden);

  function toggleMenu(options = {}) {
    const { focusOnOpen = true } = options;

    menu.querySelector('svg').classList.toggle('open');

    sidebarContainer.classList.toggle('hx:max-md:[transform:translate3d(0,-100%,0)]');
    sidebarContainer.classList.toggle('hx:max-md:[transform:translate3d(0,0,0)]');

    document.body.classList.toggle('hx:overflow-hidden');
    document.body.classList.toggle('hx:md:overflow-auto');

    const isOpen = isMenuOpen();
    menu.setAttribute('aria-expanded', isOpen ? 'true' : 'false');
    syncAriaHidden();

    if (isOpen) {
      if (focusOnOpen) {
        const firstFocusable = sidebarContainer.querySelector('a, button, input, [tabindex="0"]');
        if (firstFocusable) firstFocusable.focus();
      }
    } else {
      menu.focus();
    }
  }

  menu.addEventListener('click', (e) => {
    e.preventDefault();
    toggleMenu({ focusOnOpen: e.detail === 0 });
  });

  document.addEventListener('keydown', (e) => {
    if (e.key !== 'Escape') return;
    if (document.getElementById('hextra-search-dialog')?.open) return;
    if (mobileQuery.matches && isMenuOpen()) {
      toggleMenu();
    }
  });

  sidebarContainer.querySelectorAll('a').forEach((link) => {
    link.addEventListener('click', () => {
      if (link.getAttribute('href') && link.getAttribute('href').startsWith('#')) {
        if (window.innerWidth < 768) {
          toggleMenu();
        }
      }
    });
  });
});
