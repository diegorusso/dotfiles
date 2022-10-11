" Use the PaachPuff theme
" colorscheme peachpuff
" set background=dark

" Automatic commands
if has("autocmd")
    " Enable file type detection
    filetype plugin indent on
    " Treat .json files as .js
    autocmd BufNewFile,BufRead *.json setfiletype json syntax=javascript
    " Treat .md files as Markdown
    autocmd BufNewFile,BufRead *.md setlocal filetype=markdown
    " Treat .jenkinsfile as groovy files
    autocmd BufNewFile,BufRead *.jenkinsfile setlocal filetype=groovy

    autocmd FileType python,java,c,xml set wrap nospell
    autocmd FileType htmldjango,html,css,javascript setlocal tabstop=2 shiftwidth=2 softtabstop=2

    autocmd BufWinEnter * match ExtraWhitespace /\s\+$/
    autocmd InsertEnter * match ExtraWhitespace /\s\+\%#\@<!$/
    autocmd InsertLeave * match ExtraWhitespace /\s\+$/
    autocmd BufWinLeave * call clearmatches()

    autocmd BufReadPost *
         \ if line("'\"") > 0 && line("'\"") <= line("$") |
         \   exe "normal! g`\"" |
         \ endif
    set viminfo^=%      " Remember info about open buffers on close
endif

set nocompatible        " Make Vim more useful
set clipboard=unnamed   " Use the OS clipboard by default (on versions compiled with `+clipboard`)
set wildmenu            " Enhance command-line completion
set wildignore=*.o,*~,*.pyc
set esckeys             " Allow cursor keys in insert mode
set backspace=indent,eol,start  " Allow backspace in insert mode
set ttyfast             " Optimize for fast terminal connections
set gdefault            " Add the g flag to search/replace by default
set encoding=utf-8 nobomb   " Use UTF-8 without BOM
set shortmess=a
set cmdheight=2

let mapleader=","       " Change mapleader

" Don’t add empty newlines at the end of files
set binary
set noeol

" Centralize backups, swapfiles and undo history
set backupdir=~/.vim/backups
set directory=~/.vim/swaps
if exists("&undodir")
    set undodir=~/.vim/undo
endif
" Don’t create backups when editing files in certain directories
set backupskip=/tmp/*,/private/tmp/*

" Respect modeline in files
set modeline
set modelines=4

" Enable per-directory .vimrc files and disable unsafe commands in them
set exrc
set secure

syntax on               " Enable syntax highlighting
set cursorline          " Highlight current line

set expandtab       " tabs are converted to spac
set smarttab        " Be smart when using tabs ;)
set tabstop=4       " numbers of spaces of tab character
set shiftwidth=4    " numbers of spaces to (auto)indent
set softtabstop=4   " Number of spaces that a <Tab> counts for while performing editing  operations

" Show “invisible” characters
set lcs=tab:▸\ ,nbsp:_
set list

set hlsearch            " Highlight searches
set ignorecase          " Ignore case of searches
set incsearch           " Highlight dynamically as pattern is typed
set laststatus=2        " Always show status line
"set mouse=a             " Enable mouse in all modes
set noerrorbells        " Disable error bells
set nostartofline       " Don’t reset cursor to start of line when moving around.
set ruler               " Show the cursor position
set shortmess=atI       " Don’t show the intro message when starting Vim
set showmode            " Show the current mode
set title               " Show the filename in the window titlebar
set showcmd             " Show the (partial) command as it’s being typed

set autoread        " Set to auto read when a file is changed from the outside
set foldmethod=indent " activate folding
set nofoldenable    " no folding enabled at the beginning
set lazyredraw      " Don't redraw while executing macros (good performance config)
set magic           " For regular expressions turn magic on
set numberwidth=4   " line numbering takes up 5 spaces
set noignorecase    " ignore case when searching
set smartcase       " When searching try to be smart about cases
set nowrap          " stop lines from wrapping
set ai              " set auto indent
set si              " set smart indent
set showmatch       " Show matching brackets when text indicator is over them
set mat=2           " How many tenths of a second to blink when matching brackets
set ffs=unix,dos,mac " Use Unix as the standard file type
set switchbuf+=usetab,newtab
set scrolloff=3         " Start scrolling three lines before the horizontal window border

" Map double § to ESC (handy on MBP with touchbar)
imap §§ <Esc>

" Strip trailing whitespace (,ss)
function! StripWhitespace()
    let save_cursor = getpos(".")
    let old_query = getreg('/')
    :%s/\s\+$//e
    call setpos('.', save_cursor)
    call setreg('/', old_query)
endfunction
noremap <leader>ss :call StripWhitespace()<CR>

" Save a file as root (,W)
noremap <leader>W :w !sudo tee % > /dev/null<CR>

highlight ColorColumn ctermbg=black ctermfg=red guibg=black guifg=red
set colorcolumn=80

set statusline=%F%m%r%h%w\ [FORMAT=%{&ff}]\ [TYPE=%Y]\ [ASCII=\%03.3b]\ [HEX=\%02.2B]\ [POS=%04l,%04v]\ [%p%%]\ [LEN=%L]
set laststatus=2

highlight ExtraWhitespace ctermbg=red guibg=red
match ExtraWhitespace /\s\+$/

function! ShortTabLine()
    let ret = ''
    for i in range(tabpagenr('$'))
        " select the color group for highlighting active tab
        if i + 1 == tabpagenr()
            let ret .= '%#errorMsg#'
        else
            let ret .= '%#TabLine#'
        endif
        " find the buffer name for the tablabel
        let buflist = tabpagebuflist(i+1)
        let winnr = tabpagewinnr(i+1)
        let buffername = bufname(buflist[winnr - 1])
        let filename = fnamemodify(buffername,':t')
        " check if there is no name
        if filename == ''
            let filename = 'noname'
        endif
        " only show the first 6 letters of the name and
        " .. if the filename is more than 8 letters long
        if strlen(filename) >=8
            let ret .= '['. filename[0:5].'..]'
        else
            let ret .= '['.filename.']'
        endif
    endfor
    " after the last tab fill with TabLineFill and reset tab page #
    let ret .= '%#TabLineFill#%T'
    return ret
endfunction

set tabline=%!ShortTabLine()

" Auto install plug.vim (plugin manager)
if empty(glob('~/.vim/autoload/plug.vim'))
  silent !curl -fLo ~/.vim/autoload/plug.vim --create-dirs
    \ https://raw.githubusercontent.com/junegunn/vim-plug/master/plug.vim
  autocmd VimEnter * PlugInstall --sync | source $MYVIMRC
endif

" Specify a directory for plugins
" - For Neovim: ~/.local/share/nvim/plugged
" - Avoid using standard Vim directory names like 'plugin'
call plug#begin('~/.vim/plugged')
" Make sure you use single quotes

Plug 'psf/black',
Plug 'vim-syntastic/syntastic',
Plug 'lervag/vimtex'

" Initialize plugin system
call plug#end()

" Enable black
" autocmd BufWritePre *.py execute ':Black'

set statusline+=%#warningmsg#
set statusline+=%{SyntasticStatuslineFlag()}
set statusline+=%*
let g:syntastic_python_python_exec = 'python3'
let g:syntastic_always_populate_loc_list = 1
let g:syntastic_auto_loc_list = 1
let g:syntastic_check_on_open = 1
let g:syntastic_check_on_wq = 0
let g:syntastic_sh_shellcheck_args = "-x -e SC1091"

" let g:black_linelength = 120

" https://github.com/vim-syntastic/syntastic/issues/2169
let g:syntastic_tex_lacheck_quiet_messages = { 'regex': '\Vpossible unwanted space at' }
let g:tex_flavor = 'latex'

set spelllang=en_gb,it spellsuggest=15
autocmd FileType latex,tex,md,markdown setlocal spell
