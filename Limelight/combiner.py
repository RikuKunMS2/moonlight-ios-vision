import os
import argparse

def combine_swift_files(directory_path, output_file_path):
    """
    Finds all .swift files in a given directory, combines them into a single
    string with specified formatting, and saves them to an output file.

    Each file's content is prefixed with its filename as a comment and
    wrapped in triple backticks.

    Args:
        directory_path (str): The path to the directory containing .swift files.
        output_file_path (str): The path where the combined text file will be saved.
    """
    # Check if the provided directory exists
    if not os.path.isdir(directory_path):
        print(f"Error: Directory not found at '{directory_path}'")
        return

    # A list to hold the formatted content of each Swift file
    combined_content = []

    print(f"Searching for .swift files in '{directory_path}'...")

    try:
        # Iterate over all files in the specified directory
        for filename in sorted(os.listdir(directory_path)):
            # Check if the file has a .swift extension
            if filename.endswith(".swift"):
                print(f"  - Processing '{filename}'")
                file_path = os.path.join(directory_path, filename)

                try:
                    # Open and read the content of the Swift file
                    with open(file_path, 'r', encoding='utf-8') as f:
                        file_content = f.read()

                    # Create the header comment
                    header = f"// {filename}"

                    # Format the content as requested:
                    # ```swift
                    # // filename.swift
                    # ... swift code ...
                    # ```
                    formatted_block = f"```swift\n{header}\n{file_content}\n```"

                    # Add the formatted block to our list
                    combined_content.append(formatted_block)

                except Exception as e:
                    print(f"    - Error reading file '{filename}': {e}")

        # Check if any Swift files were found
        if not combined_content:
            print("No .swift files were found in the directory.")
            return

        # Join all the individual file blocks into a single string,
        # separated by two newlines for better readability.
        final_output = "\n\n".join(combined_content)

        # Write the final combined string to the output file
        with open(output_file_path, 'w', encoding='utf-8') as f:
            f.write(final_output)

        print(f"\nSuccessfully combined {len(combined_content)} Swift file(s) into '{output_file_path}'")

    except Exception as e:
        print(f"An unexpected error occurred: {e}")


if __name__ == "__main__":
    # --- How to use this script ---
    #
    # Run from your terminal:
    # python your_script_name.py /path/to/your/swift/files -o combined_output.txt
    #
    # Arguments:
    #   directory: The path to the folder with your .swift files.
    #   -o, --output: (Optional) The name of the file to save the output to.
    #                 Defaults to 'combined_swift_code.txt' in the script's directory.

    # Set up the command-line argument parser
    parser = argparse.ArgumentParser(
        description="Combine all .swift files in a directory into a single text file."
    )
    parser.add_argument(
        "directory",
        type=str,
        help="The path to the directory containing the .swift files."
    )
    parser.add_argument(
        "-o", "--output",
        type=str,
        default="combined_swift_code.txt",
        help="The path for the output file. If a relative path is given, it will be created in the same directory as this script. (default: combined_swift_code.txt)"
    )

    args = parser.parse_args()

    output_file_path = args.output

    # If the output path is not an absolute path, place it in the same directory as the script.
    if not os.path.isabs(output_file_path):
        # Get the directory where this script is located.
        script_directory = os.path.dirname(os.path.realpath(__file__))
        output_file_path = os.path.join(script_directory, output_file_path)

    # Call the main function with the provided arguments
    combine_swift_files(args.directory, output_file_path)
