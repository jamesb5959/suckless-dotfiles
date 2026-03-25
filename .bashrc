######################################################################
#
#
#           ██████╗  █████╗ ███████╗██╗  ██╗██████╗  ██████╗
#           ██╔══██╗██╔══██╗██╔════╝██║  ██║██╔══██╗██╔════╝
#           ██████╔╝███████║███████╗███████║██████╔╝██║     
#           ██╔══██╗██╔══██║╚════██║██╔══██║██╔══██╗██║     
#           ██████╔╝██║  ██║███████║██║  ██║██║  ██║╚██████╗
#           ╚═════╝ ╚═╝  ╚═╝╚══════╝╚═╝  ╚═╝╚═╝  ╚═╝ ╚═════╝
#
#
######################################################################

# If not running interactively, don't do anything
[[ $- != *i* ]] && return

# export  _JAVA_AWT_WM_NONREPARENTING=1

set -o vi
alias ls='ls --color=auto'
alias vim='nvim'
alias grep='grep --color=auto'
alias unzip='bsdtar xvf'
alias screenshot='ffmpeg -f x11grab -video_size 1920x1200 -i $DISPLAY -vframes 1 screen.png'
alias screenrec='ffmpeg -video_size 1920x1200 -framerate 60 -f x11grab -i :0.0+ output.mp4'
#for ly login manager. In ly the logout command doesn't work.
# alias logout='pkill -KILL -u james'

alias looking-glass-client='looking-glass-client -F -S -f /dev/kvmfr0'

encrypt() {
    if [[ $# -ne 2 ]]; then
        echo "Usage: encrypt <input_file> <output_file>"
        return 1
    fi
    local input_file="$1"
    local output_file="$2"
    if [[ "$input_file" == "$output_file" ]]; then
        echo "Error: Input and output files must be different."
        return 1
    fi
    openssl enc -aes-256-cbc -pbkdf2 -iter 100000 -salt -in "$input_file" -out "$output_file"
}

decrypt() {
    if [[ $# -ne 2 ]]; then
        echo "Usage: decrypt <input_file> <output_file>"
        return 1
    fi
    local input_file="$1"
    local output_file="$2"
    if [[ "$input_file" == "$output_file" ]]; then
        echo "Error: Input and output files must be different."
        return 1
    fi
    openssl enc -aes-256-cbc -d -pbkdf2 -iter 100000 -in "$input_file" -out "$output_file"
}


# alias encrypt = 'openssl enc -aes-256-cbc -pbkdf2 -iter 100000 -salt -in file.txt -out file.txt.enc'
# alias decrypt = 'openssl enc -aes-256-cbc -d -pbkdf2 -iter 100000 -in file.txt.enc -out file.txt.dec'

HISTTIMEFORMAT="%F %T "
HISTCONTROL=ignoredups
#PS1='[\u@\h \W]\$ '
PS1="\[\e[38;5;242m\][\[\e[38;5;72m\]\u\[\e[38;5;73m\]@\[\e[38;5;74m\]\h \[\e[1;38;5;30m\]\W\[\e[38;5;242m\]]\[\033[0m\]$ "

#PS1="\e[38;5;72m\]\u\\[\e[1;38;5;30m\] \W\[\e[38;5;242m\]\[\033[0m\] $ "
