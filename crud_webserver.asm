[BITS 64]
global _start

%define AF_INET 0x2
%define SOCKET_BACKLOG 0x0
%define O_RDONLY 0x0
%define O_WRONLY 0x1
%define O_CREAT 0q100

struc sockaddr_in
	.sin_family: resw 1
	.sin_port: resw 1
	.sin_addr: resd 1
	.sin_zero: resb 8
endstruc



section .data
	bind_sockaddr_in istruc sockaddr_in
		at sockaddr_in.sin_family, dw AF_INET ; AF_INET
		at sockaddr_in.sin_port, dw 0x5000 ; port 80
		at sockaddr_in.sin_addr, dd 0x0 ; 0.0.0.0
		at sockaddr_in.sin_zero, dd 0, 0 ; doesn't matter
	iend
	bind_sockaddr_in_len equ $ - bind_sockaddr_in

	HTTP_200_OK_RES db `HTTP/1.0 200 OK\r\n\r\n`
	HTTP_200_OK_RES_LEN equ $ - HTTP_200_OK_RES

	REQUEST_DATA_PREFIX dd `\r\n\r\n`


section .text

create_socket:
	mov rdi, AF_INET ; AF_INET
	mov rsi, 1 ; SOCK_STREAM
	mov rdx, 0

	mov rax, 41 ; socket() syscall
	syscall
	ret

bind_socket:
	; should have socket fs in rdi
	mov rsi, bind_sockaddr_in
	mov rdx, bind_sockaddr_in_len ; 4 bytes for ipv4
	mov rax, 49 ; bind syscall
	syscall
	ret

listen_socket:
	mov rax, 50
	; we should already have socket fd in rdi
	mov rsi, SOCKET_BACKLOG
	syscall
	ret

wait_for_connection:
	push rbp
	mov rbp, rsp
	sub rsp, 0x10 ; store bind() socket fs and opened socket fd
	; we have socket fs in rdi
	mov qword [rbp-0x8], rdi

	wait_for_conn_loop:
		mov rax, 0x2b ; accept syscall
		mov rsi, 0 ; dont need
		mov rdx, 0 ; dont need
		syscall ; we shoul have new socket fs in rax
		mov qword [rbp-0x10], rax

		; now fork process to make it multithreaded
		mov rax, 0x39
		syscall
		; parent should continue listening, child should handle and gtfo
		cmp rax, 0
		je wfc_child_task

		wfc_parrent_task:
			; close accepted socket and continue (child will take care of it)
			mov rdi, qword [rbp-0x10]
			mov rax, 3
			syscall
			
			mov rdi, qword [rbp-0x8]
			jmp wait_for_conn_loop
		wfc_child_task:
			; we don't need the bind() socket anymore, 
			mov rdi, qword [rbp-0x8]
			mov rax, 3
			syscall

			mov rdi, qword [rbp-0x10]
			call handle_http_request

		leave
		ret

get_filename_from_request:
	; rdi: buffer containing request
	; rsi: buffer where to save filename
	; returns nothing
	push rcx ; store current char in rcx
	xor rcx, rcx

	gfn_search_start:
		inc rdi
		cmp byte [rdi], 0x20
		jne gfn_search_start
	inc rdi

	; now search for 0x20 (space) and write all the chars to buf
	; replace the 0x20 with 0x00
	gfn_loop:	
		mov cl, byte [rdi]
		cmp rcx, 0x20
		je gfn_loop_end
		mov byte [rsi], cl
		inc rdi
		inc rsi
		jmp gfn_loop
	gfn_loop_end:
		mov byte [rsi], 0x00; write 0x00 to the byte
		pop rcx
		ret

find_post_data:
	; rdi: buffer containing request
	; rsi: request size

	; rcx: store current char

	; returns
	; rdi - location
	; rsi - remaining (size)
	push rcx
	xor rcx, rcx

	; first, find the beginning of the post data
	; it is after \r\n\r\n or REQUEST_DATA_PREFIX	
	; but we still need to search byte by byte

	fpd_search_loop:
		inc rdi
		dec rsi
		mov ecx, dword [rdi]
		cmp ecx, dword [REQUEST_DATA_PREFIX]
		jne fpd_search_loop
	add rdi, 0x4 ; skip REQUEST_DATA_PREFIX
	sub rsi, 0x4

	pop rcx
	ret

handle_http_request:
	push rbp
	mov rbp, rsp
	sub rsp, 0x888
	; rbp-0x8: new connection socket fd
	; rbp-0x408: data buffer, size: 1024 bytes
	; rbp-0x808: file buffer, size: 1024 bytes
	; rbp-0x888: where to save filename: 128 bytes
	push r8 ; store bytes read from file
	push r10 ; store bytes read from socket
	xor r10, r10
	xor r8, r8
	mov qword [rbp-0x8], rdi ; save socket fd
	mov rax, 0 ; read
	lea rsi, [rbp-0x408] ; where to read to
	mov rdx, 1024 ; read max 1024 bytes
	syscall
	mov r10, rax

	;find filename
	lea rdi, [rbp-0x408]
	lea rsi, [rbp-0x888]
	call get_filename_from_request

	; see what type of request it is
	cmp byte [rbp-0x408], 0x47 ; G for GET
	je handle_http_request_get ; GET
	jmp handle_http_request_post ; POST


	handle_http_request_post:
		
		; open file in write mode with O_CREAT mode set
		mov rax, 2
		lea rdi, [rbp-0x888]
		xor rsi, rsi
		mov rsi, O_WRONLY
		or rsi, O_CREAT
		mov rdx, 0q0777
		syscall

		; find where the request data is
		lea rdi, [rbp-0x408]
		mov rsi, r10
		call find_post_data

		; now write to file
		push rax
		push rdi
		push rsi
		mov rdi, rax
		mov rax, 1
		pop rdx
		pop rsi
		syscall

		; now close file
		pop rdi
		mov rax, 3
		syscall
		
		; now answer with response
		xor rdi, rdi
		mov rax, 1 ; write
		mov rdi, qword [rbp-0x8] ; socket fd
		mov rsi, HTTP_200_OK_RES
		mov rdx, HTTP_200_OK_RES_LEN
		syscall
		
		jmp handle_http_request_fin

	handle_http_request_get:

		; open, read file and close it
		mov rax, 2
		lea rdi, [rbp-0x888]
		mov rsi, O_RDONLY
		mov rdx, 0
		syscall

		push rax
		mov rdi, rax ; fd
		mov rax, 0
		lea rsi, [rbp-0x808]
		mov rdx, 1024
		syscall
		mov r8, rax ; store how many bytes were read

		pop rdi
		mov rax, 3
		syscall

		; now answer with response
		xor rdi, rdi
		mov rax, 1 ; write
		mov rdi, qword [rbp-0x8] ; socket fd
		mov rsi, HTTP_200_OK_RES
		mov rdx, HTTP_200_OK_RES_LEN
		syscall

		; now send file
		mov rax, 1
		mov rdi, qword [rbp-0x8]
		lea rsi, [rbp-0x808]
		mov rdx, r8
		syscall

		jmp handle_http_request_fin


	handle_http_request_fin:
		; close socket if it's still open
		mov rdi, qword [rbp-0x8]
		mov rax, 0x3
		syscall
	
		pop r10
		pop r8	
		leave
		ret 

_start:
	mov rbp, rsp
	sub rsp, 0x100 ; allocate bytes to save stuff like socket fd
	call create_socket ; we should have socket fd in rax
	mov qword [rbp-0x8], rax ; save socket fd

	mov rdi, rax
	call bind_socket	

	mov rdi, qword [rbp-0x8]
	call listen_socket

	mov rdi, qword [rbp-0x8]
	call wait_for_connection

	mov rdi, 0
	jmp exit	
exit:
    mov rdi, 0
    mov rax, 60     ; SYS_exit
    syscall


