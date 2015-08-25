import { acceptance } from "helpers/qunit-helpers";

acceptance("Hamburger Menu - Staff", { loggedIn: true });

test("Menu Items", (assert) => {
  visit("/");
  click("#toggle-hamburger-menu");
  andThen(() => {
    assert.ok(exists("#hamburger-menu .admin-link"));
    assert.ok(exists("#hamburger-menu .flagged-posts-link"));
    assert.ok(exists("#hamburger-menu .flagged-posts.badge-notification"), "it displays flag notifications");
  });
});
