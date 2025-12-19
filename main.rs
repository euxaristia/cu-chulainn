use std::io::{Read, Write};
use std::net::{TcpListener, TcpStream};
use std::fs;
use std::thread;

fn handle_client(mut stream: TcpStream) {
    let mut buffer = [0; 1024];
    
    // Read the request
    match stream.read(&mut buffer) {
        Ok(size) => {
            let request = String::from_utf8_lossy(&buffer[..size]);
            
            // Simple route parsing - check if it's a GET request
            if request.starts_with("GET") {
                // Try to read index.html
                match fs::read_to_string("index.html") {
                    Ok(html_content) => {
                        // Construct HTTP response
                        let response = format!(
                            "HTTP/1.1 200 OK\r\n\
                            Content-Type: text/html; charset=UTF-8\r\n\
                            Content-Length: {}\r\n\
                            Connection: close\r\n\r\n\
                            {}",
                            html_content.len(),
                            html_content
                        );
                        
                        // Send response
                        if let Err(e) = stream.write_all(response.as_bytes()) {
                            eprintln!("Error sending response: {}", e);
                        }
                    }
                    Err(e) => {
                        let error_msg = format!("Error reading index.html: {}", e);
                        let response = format!(
                            "HTTP/1.1 500 Internal Server Error\r\n\
                            Content-Type: text/plain\r\n\
                            Content-Length: {}\r\n\
                            Connection: close\r\n\r\n\
                            {}",
                            error_msg.len(),
                            error_msg
                        );
                        let _ = stream.write_all(response.as_bytes());
                    }
                }
            } else {
                // Method not allowed
                let response = "HTTP/1.1 405 Method Not Allowed\r\n\
                               Connection: close\r\n\r\n";
                let _ = stream.write_all(response.as_bytes());
            }
        }
        Err(e) => {
            eprintln!("Error reading from stream: {}", e);
        }
    }
    
    // Flush the stream to ensure data is sent
    let _ = stream.flush();
}

fn main() {
    let address = "127.0.0.1:8080";
    let listener = TcpListener::bind(address).expect("Failed to bind to address");
    
    println!("Server listening on http://{}", address);
    println!("Open http://localhost:8080 in your browser");
    
    for stream in listener.incoming() {
        match stream {
            Ok(stream) => {
                // Handle each connection in a new thread
                thread::spawn(|| {
                    handle_client(stream);
                });
            }
            Err(e) => {
                eprintln!("Error accepting connection: {}", e);
            }
        }
    }
}

