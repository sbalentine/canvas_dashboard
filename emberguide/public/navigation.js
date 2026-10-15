document.addEventListener("DOMContentLoaded", () => {
  const dashboardNav = document.querySelector(".dashboard-nav");
  const dashboardNavToggle = document.querySelector(".dashboard-nav-toggle");

  if (!dashboardNav || !dashboardNavToggle) return;

  const closeNavigation = () => {
    dashboardNav.classList.remove("is-open");
    dashboardNavToggle.setAttribute("aria-expanded", "false");
    dashboardNavToggle.setAttribute("aria-label", "Open navigation menu");
  };

  dashboardNavToggle.addEventListener("click", () => {
    const isOpen = dashboardNav.classList.toggle("is-open");

    dashboardNavToggle.setAttribute("aria-expanded", isOpen.toString());
    dashboardNavToggle.setAttribute(
      "aria-label",
      isOpen ? "Close navigation menu" : "Open navigation menu"
    );
  });

  document.addEventListener("keydown", (event) => {
    if (event.key !== "Escape" || !dashboardNav.classList.contains("is-open")) {
      return;
    }

    closeNavigation();
    dashboardNavToggle.focus();
  });

  window.addEventListener("resize", () => {
    if (window.innerWidth > 700) closeNavigation();
  });
});
