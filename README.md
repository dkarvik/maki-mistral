# maki-mistral

A Maki plugin providing web search and image generation through the Mistral API.

## Setup

Add this to `~/.config/maki/init.lua`:

```lua
maki.pack.add({ "https://github.com/dkarvik/maki-mistral.git" })
```

Sign in to Maki's Mistral provider with an API key and approve the package permissions.

## Tools

* `mistral_search`: Search the web with Mistral, with optional premium search
* `mistral_image_generation`: Generate or edit images
