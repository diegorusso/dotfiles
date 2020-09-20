#!/usr/bin/env bash

# Install all homebrew packages inside Brewfile

# Check for Homebrew Installation
if ! which brew > /dev/null; then
     # Install Homebrew
     /usr/bin/ruby -e "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/master/install)"
fi;

# Update Homebrew
brew update

# Upgrade any already-installed formulae.
brew upgrade

# Install everything inside Brewfile
brew bundle

# Save Homebrew’s installed location.
BREW_PREFIX=$(brew --prefix)

# Switch to using brew-installed bash as default shell
if ! fgrep -q "${BREW_PREFIX}/bin/bash" /etc/shells; then
  echo "${BREW_PREFIX}/bin/bash" | sudo tee -a /etc/shells;
  chsh -s "${BREW_PREFIX}/bin/bash";
fi;

# Remove outdated versions from the cellar.
brew cleanup
