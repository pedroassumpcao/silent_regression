defmodule SilentRegressionWeb.Layouts do
  @moduledoc """
  This module holds layouts and related functionality
  used by your application.
  """
  use SilentRegressionWeb, :html

  # Embed all files in layouts/* within this module.
  # The default root.html.heex file contains the HTML
  # skeleton of your application, namely HTML headers
  # and other static content.
  embed_templates "layouts/*"

  @doc """
  Renders your app layout.

  This function is typically invoked from every template,
  and it often contains your application menu, sidebar,
  or similar.

  ## Examples

      <Layouts.app flash={@flash}>
        <h1>Content</h1>
      </Layouts.app>

  """
  attr :flash, :map, required: true, doc: "the map of flash messages"

  attr :current_scope, :map,
    default: nil,
    doc: "the current [scope](https://phoenix.hexdocs.pm/scopes.html)"

  slot :inner_block, required: true

  def app(assigns) do
    ~H"""
    <div class="min-h-screen bg-background text-foreground">
      <header class="sticky top-0 z-40 border-b border-border/75 bg-background/90 backdrop-blur-xl">
        <div class="mx-auto flex h-16 max-w-7xl items-center justify-between gap-4 px-4 sm:px-6 lg:px-8">
          <.link
            href={~p"/"}
            id="public-brand"
            class="inline-flex min-w-0 items-center gap-3 font-semibold tracking-tight"
          >
            <span class="grid size-9 shrink-0 place-items-center rounded-xl bg-primary text-primary-foreground shadow-sm shadow-primary/20">
              <span class="size-2.5 rounded-full bg-current"></span>
            </span>
            <span class="truncate">Silent Regression</span>
          </.link>

          <nav
            class="hidden items-center gap-6 text-sm text-muted-foreground md:flex"
            aria-label="Main"
          >
            <.link href={~p"/" <> "#workflows"} class="transition-colors hover:text-foreground">
              Best-fit workflows
            </.link>
            <.link href={~p"/" <> "#how-it-works"} class="transition-colors hover:text-foreground">
              How it works
            </.link>
            <.link href={~p"/security"} class="transition-colors hover:text-foreground">
              Security
            </.link>
          </nav>

          <.button
            href={~p"/design-partner/apply"}
            variant="primary"
            class="inline-flex h-9 shrink-0 items-center justify-center rounded-lg bg-primary px-3 text-sm font-semibold text-primary-foreground shadow-sm transition-all hover:bg-primary/90 focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-ring focus-visible:ring-offset-2 sm:px-4"
          >
            <span class="hidden sm:inline">Apply for access</span>
            <span class="sm:hidden">Apply</span>
          </.button>
        </div>
      </header>

      <main>
        {render_slot(@inner_block)}
      </main>

      <footer class="border-t border-border bg-card/50">
        <div class="mx-auto grid max-w-7xl gap-8 px-4 py-10 sm:px-6 md:grid-cols-[1fr_auto] md:items-end lg:px-8">
          <div>
            <div class="flex items-center gap-3 text-sm font-semibold">
              <span class="grid size-8 place-items-center rounded-xl bg-primary text-primary-foreground">
                <span class="size-2 rounded-full bg-current"></span>
              </span>
              Silent Regression
            </div>
            <p class="mt-3 max-w-md text-sm leading-6 text-muted-foreground">
              Deterministic monitoring for critical LLM workflows. Private, controlled, and built alongside design partners.
            </p>
          </div>
          <nav class="flex flex-wrap gap-x-5 gap-y-3 text-sm text-muted-foreground" aria-label="Legal">
            <.link href={~p"/security"} class="transition-colors hover:text-foreground">Security</.link>
            <.link href={~p"/privacy"} class="transition-colors hover:text-foreground">Privacy</.link>
            <.link href={~p"/terms"} class="transition-colors hover:text-foreground">Terms</.link>
          </nav>
        </div>
      </footer>
    </div>

    <.flash_group flash={@flash} />
    """
  end

  @doc """
  Shows the flash group with standard titles and content.

  ## Examples

      <.flash_group flash={@flash} />
  """
  attr :flash, :map, required: true, doc: "the map of flash messages"
  attr :id, :string, default: "flash-group", doc: "the optional id of flash container"

  def flash_group(assigns) do
    ~H"""
    <div id={@id} aria-live="polite">
      <.flash kind={:info} flash={@flash} />
      <.flash kind={:error} flash={@flash} />

      <.flash
        id="client-error"
        kind={:error}
        title={gettext("We can't find the internet")}
        phx-disconnected={
          show(".phx-client-error #client-error")
          |> JS.remove_attribute("hidden", to: ".phx-client-error #client-error")
        }
        phx-connected={hide("#client-error") |> JS.set_attribute({"hidden", ""})}
        hidden
      >
        {gettext("Attempting to reconnect")}
        <.icon name="hero-arrow-path" class="ml-1 size-3 motion-safe:animate-spin" />
      </.flash>

      <.flash
        id="server-error"
        kind={:error}
        title={gettext("Something went wrong!")}
        phx-disconnected={
          show(".phx-server-error #server-error")
          |> JS.remove_attribute("hidden", to: ".phx-server-error #server-error")
        }
        phx-connected={hide("#server-error") |> JS.set_attribute({"hidden", ""})}
        hidden
      >
        {gettext("Attempting to reconnect")}
        <.icon name="hero-arrow-path" class="ml-1 size-3 motion-safe:animate-spin" />
      </.flash>
    </div>
    """
  end
end
